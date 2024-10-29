use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use cardano/address.{Address, Credential, Script}
use cardano/assets.{AssetName, Value, add, flatten, quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use finance.{
  can_liquidate, get_collateral_value_in_principal_currency, get_remaining_debt,
  get_repayment_amount, is_recasting_permitted, is_repayment_late,
}
use types/datum.{
  ActiveDatum, DepositDatum, DutchAuctionDatum, InterestOnRemainingPrincipal,
  Liquidation, NoLiquidationDutchAuctionClaim, NoLiquidationFullCollateralClaim,
  PoolDatum, PrincipalAndInterestOnInstallments, RepaymentMode,
}
use types/general.{Asset, CollateralAsset}
use types/redeemer.{
  ActiveWithdrawRedeemer, AddCollateral, Aggregated, Claim, Dedicated,
  OraclePriceFeed, PoolAction, PoolSpendRedeemer, Pooled, Recast, Repay,
}
use utils.{
  address_in_signatures, authorize_action, get_inputs_from_sc, get_outputs_to_sc,
  get_own_hash, is_nft_spent, is_output_to_sc, quantity_of_policy_id,
  retrieve_oracle_data, safe_list_at, token_b_needed_to_purchase_token_a,
  validate_oracle_ref_input, validity_range_within_an_hour,
}

validator activeLoan(
  borrowerTokenPolicyId: ByteArray,
  lenderTokenPolicyId: ByteArray,
  depositScriptHash: ByteArray,
  dutchAuctionScriptHash: ByteArray,
  dutchAuctionStartingIncreasePerMille: Int,
  adminAddress: Address,
) {
  spend(
    _datumOpt: Option<PoolDatum>,
    _redeemer: PoolSpendRedeemer,
    input: OutputReference,
    self: Transaction,
  ) {
    let ownScriptHash = get_own_hash(input, self.inputs)
    list.any(
      self.withdrawals,
      fn(withdrawal) {
        when withdrawal is {
          Pair(Script(scriptHash), _amnt) -> scriptHash == ownScriptHash
          _ -> False
        }
      },
    )
  }

  withdraw(
    redeemer: ActiveWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(ownScriptHash) = credential
    let scInputs = get_inputs_from_sc(self.inputs, ownScriptHash)
    //Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
    expect length(scInputs) == length(redeemer.actionForEachInput)
    expect Finite(validFrom) = self.validity_range.lower_bound.bound_type
    expect Finite(validTo) = self.validity_range.upper_bound.bound_type

    list.indexed_foldr(
      scInputs,
      True,
      fn(index, input, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: ActiveDatum = inputDatum
        let redeemerAction = safe_list_at(redeemer.actionForEachInput, index)

        when redeemerAction is {
          Claim(bondInputIndex, collateralOracleInputIndex) -> {
            expect Some(actualBondInput) = list.at(self.inputs, bondInputIndex)
            and {
              is_nft_spent(
                lenderTokenPolicyId,
                datum.lenderAssetName,
                actualBondInput,
              ),
              when datum.commonData.liquidationMode is {
                NoLiquidationFullCollateralClaim -> todo
                NoLiquidationDutchAuctionClaim -> todo
                Liquidation(lTV, lTVDivider, partialLiquidation) -> {
                  let oracleRefInput =
                    safe_list_at(
                      self.reference_inputs,
                      collateralOracleInputIndex,
                    )
                  expect Some(oraclePriceFeed) =
                    retrieve_oracle_data(
                      oracleRefInput,
                      self.redeemers,
                      validTo,
                      datum.collateral,
                    )
                  let collateralValueInPrincipalCurrency =
                    get_collateral_value_in_principal_currency(
                      oraclePriceFeed,
                      datum.collateral,
                      input.output.value,
                    )
                  and {
                    validate_oracle_ref_input(
                      oracleRefInput.output.value,
                      datum.collateral,
                    ),
                    or {
                      is_repayment_late(
                        validFrom,
                        datum.lendDate,
                        datum.commonData.initialGracePeriod,
                        datum.repaidInstallments,
                        datum.commonData.installmentPeriod,
                        datum.commonData.repaymentTimeWindow,
                      ),
                      can_liquidate(
                        collateralValueInPrincipalCurrency,
                        datum.principalAmount,
                        datum.principalDivider,
                        lTV,
                        lTVDivider,
                      ),
                    },
                    or {
                      partialLiquidation == False,
                      difference_sent_to_borrower(
                        collateralValueInPrincipalCurrency: collateralValueInPrincipalCurrency,
                        totalDebtInPrincipalCurrency: get_remaining_debt(
                          datum.commonData.repaymentMode,
                          datum.principalAmount,
                          datum.principalDivider,
                          datum.commonData.interestRate,
                          datum.commonData.totalInstallments,
                          datum.repaidInstallments,
                        ),
                        borrowerTokenPolicyId: borrowerTokenPolicyId,
                        borrowerAssetName: datum.borrowerAssetName,
                        principalAssetPolicyId: datum.commonData.principalAsset.policyId,
                        principalAssetName: datum.commonData.principalAsset.assetName,
                        differenceOutput: safe_list_at(self.outputs, index),
                        depositScriptHash: depositScriptHash,
                      ),
                    },
                  }
                }
              },
            }
          }

          Repay(bondInputIndex) -> {
            expect Some(bondInput) = list.at(self.inputs, bondInputIndex)
            expect Some(repaymentOutput) =
              list.at(get_outputs_to_sc(self.outputs, depositScriptHash), index)
            let isLate =
              is_repayment_late(
                validFrom,
                datum.lendDate,
                datum.commonData.initialGracePeriod,
                datum.repaidInstallments,
                datum.commonData.installmentPeriod,
                datum.commonData.repaymentTimeWindow,
              )
            let nextRepaymentAmount =
              get_repayment_amount(
                datum.commonData.repaymentMode,
                datum.principalAmount,
                datum.principalDivider,
                datum.commonData.interestRate,
                datum.commonData.totalInstallments,
                datum.repaidInstallments,
                isLate,
                datum.commonData.penaltyFeeForLateRepayment,
              )
            and {
              is_nft_spent(
                borrowerTokenPolicyId,
                datum.borrowerAssetName,
                bondInput,
              ),
              validate_output_to_deposit_for_repayment(
                repaymentOutput,
                datum.commonData.principalAsset,
                nextRepaymentAmount,
                datum.lenderAssetName,
              ),
              or {
                datum.repaidInstallments == datum.commonData.totalInstallments - 1,
                validate_output_to_active_loan_for_repayment(
                  safe_list_at(
                    get_outputs_to_sc(self.outputs, ownScriptHash),
                    index,
                  ),
                  datum,
                  datum.repaidInstallments + 1,
                  input.output.value,
                  ownScriptHash,
                ),
              },
            }
          }
          AddCollateral(bondInputIndex, addedCollateralAmount) -> {
            expect Some(bondInput) = list.at(self.inputs, bondInputIndex)
            expect Some(activeLoanOutput) =
              list.at(get_outputs_to_sc(self.outputs, ownScriptHash), index)
            and {
              addedCollateralAmount > 0,
              is_nft_spent(
                borrowerTokenPolicyId,
                datum.borrowerAssetName,
                bondInput,
              ),
              validate_output_to_active_loan_for_adding_collateral(
                activeLoanOutput,
                datum,
                addedCollateralAmount,
                input.output.value,
                ownScriptHash,
              ),
            }
          }
          Recast(bondInputIndex, principalPaid) -> todo
        }
      },
    )
  }

  else(ctx: ScriptContext) {
    address_in_signatures(ctx.transaction.extra_signatories, adminAddress)
  }
}

fn difference_sent_to_borrower(
  collateralValueInPrincipalCurrency: Int,
  totalDebtInPrincipalCurrency: Int,
  borrowerTokenPolicyId: ByteArray,
  borrowerAssetName: AssetName,
  principalAssetPolicyId: ByteArray,
  principalAssetName: AssetName,
  differenceOutput: Output,
  depositScriptHash: ByteArray,
) {
  expect Script(scriptHash) = differenceOutput.address.payment_credential
  expect InlineDatum(outputDatum) = differenceOutput.datum
  expect parsedDatum: DepositDatum = outputDatum

  let borrowerAsset =
    Asset { policyId: borrowerTokenPolicyId, assetName: borrowerAssetName }
  let newDatum =
    DepositDatum { action: "partial_liquidation", ownerAsset: borrowerAsset }
  //TODO Add liquidation fee?
  let remainingAmount =
    collateralValueInPrincipalCurrency - totalDebtInPrincipalCurrency

  let containsCorrectAmount =
    quantity_of(
      differenceOutput.value,
      principalAssetPolicyId,
      principalAssetName,
    ) == remainingAmount

  let isDatumCorrect = parsedDatum == newDatum
  or {
    remainingAmount < 0,
    and {
      containsCorrectAmount,
      scriptHash == depositScriptHash,
      isDatumCorrect,
      length(flatten(differenceOutput.value)) <= 21,
    },
  }
}

fn validate_output_to_deposit_for_repayment(
  repaymentOutput: Output,
  loanAsset: Asset,
  repaymentAmount: Int,
  lenderAssetName: AssetName,
) {
  expect InlineDatum(outputDatum) = repaymentOutput.datum
  expect parsedDatum: DepositDatum = outputDatum

  let lenderAsset =
    Asset { policyId: lenderTokenPolicyId, assetName: lenderAssetName }
  let newDatum =
    DepositDatum { action: "installment_repayment", ownerAsset: lenderAsset }
  let isDatumCorrect = parsedDatum == newDatum
  let dosProtection = length(flatten(repaymentOutput.value)) <= 3
  and {
    is_output_to_sc(repaymentOutput, depositScriptHash),
    quantity_of(repaymentOutput.value, loanAsset.policyId, loanAsset.assetName) >= repaymentAmount,
    isDatumCorrect,
    dosProtection,
  }
}

fn validate_output_to_active_loan_for_repayment(
  activeLoanOutput: Output,
  datum: ActiveDatum,
  newRepaidInstallments: Int,
  loanValue: Value,
  ownScriptHash: ByteArray,
) {
  expect InlineDatum(outputDatum) = activeLoanOutput.datum
  expect parsedDatum: ActiveDatum = outputDatum

  let newDatum =
    ActiveDatum {
      commonData: datum.commonData,
      borrowerAssetName: datum.borrowerAssetName,
      lenderAssetName: datum.lenderAssetName,
      collateral: datum.collateral,
      principalAmount: datum.principalAmount,
      principalDivider: datum.principalDivider,
      lendDate: datum.lendDate,
      repaidInstallments: newRepaidInstallments,
      doneRecasts: datum.doneRecasts,
    }
  let isDatumCorrect = parsedDatum == newDatum
  and {
    is_output_to_sc(activeLoanOutput, ownScriptHash),
    activeLoanOutput.value == loanValue,
    isDatumCorrect,
  }
}

fn validate_output_to_active_loan_for_adding_collateral(
  activeLoanOutput: Output,
  datum: ActiveDatum,
  additionalCollateralAmount: Int,
  loanValue: Value,
  ownScriptHash: ByteArray,
) {
  expect InlineDatum(outputDatum) = activeLoanOutput.datum
  expect parsedDatum: ActiveDatum = outputDatum

  let correctValue =
    if datum.collateral.maybeAssetName == None {
      //TODO the Value must be the same as before except for the quantity of tokens with same collateral's policyId
      //TODO the max value must be 21 tokens for DoS purposes
      todo
    } else {
      expect Some(assetName) = datum.collateral.maybeAssetName
      let expectedValue =
        add(
          loanValue,
          datum.collateral.policyId,
          assetName,
          additionalCollateralAmount,
        )
      activeLoanOutput.value == expectedValue
    }

  and {
    is_output_to_sc(activeLoanOutput, ownScriptHash),
    parsedDatum == datum,
    correctValue,
  }
}

fn validate_output_to_active_loan_for_recasting() {
  todo
}

fn correct_output_to_dutch_auction(
  activeLoanInput: Input,
  borrower_bond_input: Input,
  dutchAuctionOutput: Output,
  validTo: Int,
) {
  todo
}
