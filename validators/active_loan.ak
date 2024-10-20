use aiken/collection/list.{length}
use aiken/crypto.{sha2_256}
use aiken/interval.{Finite, Interval}
use cardano/address.{Address, Credential, Script}
use cardano/assets.{AssetName, Value, flatten, quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use types/datum.{
  ActiveDatum, DepositDatum, DutchAuctionDatum, InterestOnRemainingPrincipal,
  Liquidation, NoLiquidationDutchAuctionClaim, NoLiquidationFullCollateralClaim,
  PoolDatum, PrincipalAndInterestOnInstallments, RepaymentDatum, RepaymentMode,
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
  repaymentScriptHash: ByteArray,
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
        expect Finite(validFrom) = self.validity_range.lower_bound.bound_type
        expect Finite(validTo) = self.validity_range.upper_bound.bound_type

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
                NoLiquidationFullCollateralClaim ->
                  is_repayment_late(
                    validFrom,
                    datum.lendDate,
                    datum.commonData.initialGracePeriod,
                    datum.repaidInstallments,
                    datum.commonData.installmentPeriod,
                    datum.commonData.repaymentTimeWindow,
                  )
                NoLiquidationDutchAuctionClaim -> {
                  expect Finite(validTo) =
                    self.validity_range.upper_bound.bound_type
                  expect Some(dutchAuctionOutput) =
                    list.at(
                      get_outputs_to_sc(self.outputs, dutchAuctionScriptHash),
                      index,
                    )
                  and {
                    is_repayment_late(
                      validFrom,
                      datum.lendDate,
                      datum.commonData.initialGracePeriod,
                      datum.repaidInstallments,
                      datum.commonData.installmentPeriod,
                      datum.commonData.repaymentTimeWindow,
                    ),
                    correct_output_to_dutch_auction(
                      input,
                      actualBondInput,
                      dutchAuctionOutput,
                      validTo,
                    ),
                  }
                }
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
                  let collateralAdaValue =
                    get_collateral_ada_value(oraclePriceFeed)
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
                        collateralAdaValue,
                        datum.principalAmount,
                        datum.principalDivider,
                        lTV,
                        lTVDivider,
                      ),
                    },
                    or {
                      partialLiquidation == False,
                      difference_sent_to_borrower(
                        collateralAdaValue: collateralAdaValue,
                        totalDebtInAda: get_remaining_debt(
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
                        repaymentScriptHash: repaymentScriptHash,
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
              list.at(
                get_outputs_to_sc(self.outputs, repaymentScriptHash),
                index,
              )
            //TODO Add repayment penalty
            let nextRepaymentAmount =
              get_repayment_amount(
                datum.commonData.repaymentMode,
                datum.principalAmount,
                datum.principalDivider,
                datum.commonData.interestRate,
                datum.commonData.totalInstallments,
                datum.repaidInstallments,
              )
            and {
              is_nft_spent(
                borrowerTokenPolicyId,
                datum.borrowerAssetName,
                bondInput,
              ),
              validate_output_to_repayment(
                repaymentOutput,
                datum.commonData.principalAsset,
                nextRepaymentAmount,
                datum.lenderAssetName,
                datum.commonData.totalInstallments,
                datum.repaidInstallments,
              ),
              or {
                datum.repaidInstallments == datum.commonData.totalInstallments - 1,
                validate_output_to_active_loan_for_repayment(),
              },
            }
          }
          AddCollateral(bondInputIndex, addedCollateralAmount) -> {
            expect Some(bondInput) = list.at(self.inputs, bondInputIndex)
            and {
              addedCollateralAmount > 0,
              is_nft_spent(
                borrowerTokenPolicyId,
                datum.borrowerAssetName,
                bondInput,
              ),
              validate_output_to_active_loan_for_adding_collateral(),
            }
          }
          Recast(bondInputIndex, principalPaid) -> {
            expect Some(bondInput) = list.at(self.inputs, bondInputIndex)
            expect Some(repaymentOutput) =
              list.at(
                get_outputs_to_sc(self.outputs, repaymentScriptHash),
                index,
              )
            let debtAfterRecasting =
              get_remaining_debt(
                datum.commonData.repaymentMode,
                datum.principalAmount,
                datum.principalDivider,
                datum.commonData.interestRate,
                datum.commonData.totalInstallments,
                datum.repaidInstallments,
              ) - principalPaid
            and {
              principalPaid > 0,
              is_nft_spent(
                borrowerTokenPolicyId,
                datum.borrowerAssetName,
                bondInput,
              ),
              is_recasting_permitted(
                datum.commonData.repaymentMode,
                datum.doneRecasts,
              ),
              or {
                and {
                  debtAfterRecasting > 0,
                  validate_output_to_repayment(
                    repaymentOutput,
                    datum.commonData.principalAsset,
                    principalPaid,
                    datum.lenderAssetName,
                    datum.commonData.totalInstallments,
                    datum.repaidInstallments,
                  ),
                  validate_output_to_active_loan_for_recasting(),
                },
                validate_output_to_repayment(
                  repaymentOutput,
                  datum.commonData.principalAsset,
                  principalPaid,
                  datum.lenderAssetName,
                  datum.commonData.totalInstallments,
                  datum.commonData.totalInstallments,
                ),
              },
            }
          }
        }
      },
    )
  }

  else(ctx: ScriptContext) {
    address_in_signatures(ctx.transaction.extra_signatories, adminAddress)
  }
}

fn is_repayment_late(
  validFrom: Int,
  lendDate: Int,
  initialGracePeriod: Int,
  repaidInstallments: Int,
  installmentPeriod: Int,
  repaymentTimeWindow: Int,
) {
  let periodToLatestPaidInstallment = repaidInstallments * installmentPeriod
  validFrom > lendDate + initialGracePeriod + periodToLatestPaidInstallment + repaymentTimeWindow
}

fn correct_output_to_dutch_auction(
  activeLoanInput: Input,
  borrower_bond_input: Input,
  dutchAuctionOutput: Output,
  validTo: Int,
) {
  expect InlineDatum(outputDatum) = dutchAuctionOutput.datum
  expect parsedDatum: DutchAuctionDatum = outputDatum
  let borrowerAddress = borrower_bond_input.output.address

  //   let newDatum =
  //     DutchAuctionDatum {
  //       ownerAuthHash: lenderAuthHash,
  //       ownerAddress: lenderAuthHash,
  //       currency: datum.commonData.principalAsset,
  //       startingPrice: get_remaining_debt() * dutchAuctionStartingIncreasePerMille / 1000,
  //       loweringAmount: dutchAuctionLoweringAmount,
  //       loweringFrequency: dutchAuctionLoweringFrequency,
  //       minPriceToWithdraw: dutchAuctionMinPriceToWithdraw,
  //       startDate: validTo,
  //       liquidatedBorrowerAddress: borrowerAddress,
  //       debtAmount: get_remaining_debt(),
  //     }
  let isDatumCorrect = True
  //parsedDatum == newDatum
  and {
    is_output_to_sc(dutchAuctionOutput, dutchAuctionScriptHash),
    activeLoanInput.output.value == dutchAuctionOutput.value,
    isDatumCorrect,
  }
}

fn can_liquidate(
  collateralAdaValue: Int,
  principalAmount: Int,
  principalDivider: Int,
  ltv: Int,
  lTVDivider: Int,
) {
  //TODO use dividers
  //TODO funziona per principal non ada?
  //TODO Use rational library?
  collateralAdaValue / principalAmount < ltv
}

fn get_collateral_ada_value(oraclePriceFeed: OraclePriceFeed) {
  todo
}

fn difference_sent_to_borrower(
  collateralAdaValue: Int,
  totalDebtInAda: Int,
  borrowerTokenPolicyId: ByteArray,
  borrowerAssetName: AssetName,
  principalAssetPolicyId: ByteArray,
  principalAssetName: AssetName,
  differenceOutput: Output,
  repaymentScriptHash: ByteArray,
) {
  expect Script(scriptHash) = differenceOutput.address.payment_credential
  expect InlineDatum(outputDatum) = differenceOutput.datum
  expect parsedDatum: DepositDatum = outputDatum

  let borrowerAsset =
    Asset { policyId: borrowerTokenPolicyId, assetName: borrowerAssetName }
  let newDatum =
    DepositDatum { action: "partial_liquidation", ownerAsset: borrowerAsset }
  //TODO Add liquidation fee?
  let remainingAmount = collateralAdaValue - totalDebtInAda

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
      scriptHash == repaymentScriptHash,
      isDatumCorrect,
      length(flatten(differenceOutput.value)) <= 21,
    },
  }
}

fn get_repayment_amount(
  repaymentMode: RepaymentMode,
  principal: Int,
  principalDivider: Int,
  interestRate: Int,
  totalInstallments: Int,
  repaidInstallments: Int,
) {
  todo
}

fn validate_output_to_repayment(
  repaymentOutput: Output,
  loanAsset: Asset,
  repaymentAmount: Int,
  lenderAssetName: AssetName,
  totalInstallments: Int,
  repaidInstallments: Int,
) {
  expect InlineDatum(outputDatum) = repaymentOutput.datum
  expect parsedDatum: RepaymentDatum = outputDatum
  let isFinalRepayment = repaidInstallments == totalInstallments - 1

  let newDatum =
    RepaymentDatum {
      lenderNFT: lenderAssetName,
      installmentsContained: 1,
      installmentsPaidSoFar: repaidInstallments + 1,
      isFinalRepayment,
    }
  let isDatumCorrect = parsedDatum == newDatum
  let dosProtection = length(flatten(repaymentOutput.value)) <= 3
  and {
    is_output_to_sc(repaymentOutput, repaymentScriptHash),
    quantity_of(repaymentOutput.value, loanAsset.policyId, loanAsset.assetName) >= repaymentAmount,
    isDatumCorrect,
    dosProtection,
  }
}

fn validate_output_to_active_loan_for_repayment() {
  todo
}

fn is_recasting_permitted(repaymentMode: RepaymentMode, doneRecasts: Int) {
  expect InterestOnRemainingPrincipal(max_possible_recasts) = repaymentMode
  and {
    max_possible_recasts > 0,
    doneRecasts < max_possible_recasts,
  }
}

fn validate_output_to_active_loan_for_adding_collateral() {
  todo
}

fn validate_output_to_active_loan_for_recasting() {
  todo
}

//TODO Use dividers
//TODO Use rational library?
fn get_remaining_debt(
  repaymentMode: RepaymentMode,
  principal: Int,
  principalDivider: Int,
  interestRate: Int,
  totalInstallments: Int,
  repaidInstallments: Int,
) {
  when repaymentMode is {
    InterestOnRemainingPrincipal(..) -> todo
    PrincipalAndInterestOnInstallments -> {
      let totalInterest = principal * interestRate / 1000
      let singleInstallmentAmount =
        ( principal + totalInterest ) / totalInstallments
      ( totalInstallments - repaidInstallments ) * singleInstallmentAmount
    }
  }
}
