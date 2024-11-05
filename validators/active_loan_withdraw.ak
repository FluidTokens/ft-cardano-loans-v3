use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use cardano/address.{Address, Credential, Script, StakeCredential}
use cardano/assets.{AssetName, Value, add, flatten, quantity_of}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use finance.{
  can_liquidate, get_collateral_value_in_principal_currency, get_remaining_debt,
  get_repayment_amount, is_recasting_permitted, is_repayment_late,
}
use types/datum.{
  ActiveDatum, Liquidation, NoLiquidationDutchAuctionClaim,
  NoLiquidationFullCollateralClaim, RepaymentDatum, RepaymentDatumWithBond,
}
use types/general.{Asset, CollateralAsset}
use types/redeemer.{ActiveWithdrawRedeemer, AddCollateral, Claim, Recast, Repay}
use utils.{
  get_inputs_from_sc_or_delegated_to_sc, get_outputs_to_sc_or_delegated_to_sc,
  is_nft_spent, is_output_to_sc, quantity_of_policy_id, retrieve_oracle_data,
  safe_list_at, validate_oracle_ref_input, value_without_policy_id_as_list,
}

validator activeLoan(
  borrowerTokenPolicyId: ByteArray,
  lenderTokenPolicyId: ByteArray,
  repaymentScriptHash: ByteArray,
  dutchAuctionScriptHash: ByteArray,
) {
  withdraw(
    redeemer: ActiveWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(ownScriptHash) = credential
    let scInputs =
      get_inputs_from_sc_or_delegated_to_sc(self.inputs, ownScriptHash)
    //Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
    expect length(scInputs) == length(redeemer.actionForEachInput)
    expect Finite(validFrom) = self.validity_range.lower_bound.bound_type
    expect Finite(validTo) = self.validity_range.upper_bound.bound_type

    list.indexed_foldr(
      scInputs,
      True,
      fn(index, inputAndCIP113Control, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        let input = inputAndCIP113Control.1st
        let isCIP113 = inputAndCIP113Control.2nd
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
                      get_outputs_to_sc_or_delegated_to_sc(
                        self.outputs,
                        dutchAuctionScriptHash,
                        isCIP113,
                      ),
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
                    validate_output_to_dutch_auction(
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
                get_outputs_to_sc_or_delegated_to_sc(
                  self.outputs,
                  repaymentScriptHash,
                  isCIP113,
                ),
                index,
              )
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
                isLate,
                datum.commonData.penaltyFeeForLateRepayment,
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
                "installment_repayment",
              ),
              or {
                datum.repaidInstallments == datum.commonData.totalInstallments - 1,
                validate_output_to_active_loan_for_repayment(
                  safe_list_at(
                    get_outputs_to_sc_or_delegated_to_sc(
                      self.outputs,
                      ownScriptHash,
                      isCIP113,
                    ),
                    index,
                  ),
                  datum,
                  datum.repaidInstallments + 1,
                  input.output.value,
                  ownScriptHash,
                  input.output.address.stake_credential,
                  isCIP113,
                ),
              },
            }
          }
          AddCollateral(bondInputIndex, addedCollateralAmount) -> {
            expect Some(bondInput) = list.at(self.inputs, bondInputIndex)
            expect Some(activeLoanOutput) =
              list.at(
                get_outputs_to_sc_or_delegated_to_sc(
                  self.outputs,
                  ownScriptHash,
                  isCIP113,
                ),
                index,
              )
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
                input.output.address.stake_credential,
                isCIP113,
              ),
            }
          }
          Recast(bondInputIndex, principalPaid) -> {
            expect Some(bondInput) = list.at(self.inputs, bondInputIndex)
            expect Some(repaymentOutput) =
              list.at(
                get_outputs_to_sc_or_delegated_to_sc(
                  self.outputs,
                  repaymentScriptHash,
                  isCIP113,
                ),
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
              validate_output_to_repayment(
                repaymentOutput,
                datum.commonData.principalAsset,
                principalPaid,
                datum.lenderAssetName,
                "recast",
              ),
              or {
                debtAfterRecasting == 0,
                and {
                  debtAfterRecasting > 0,
                  {
                    expect Some(activeLoanOutput) =
                      list.at(
                        get_outputs_to_sc_or_delegated_to_sc(
                          self.outputs,
                          ownScriptHash,
                          isCIP113,
                        ),
                        index,
                      )
                    validate_output_to_active_loan_for_recasting(
                      activeLoanOutput,
                      datum,
                      principalPaid,
                      input.output.value,
                      ownScriptHash,
                      input.output.address.stake_credential,
                      isCIP113,
                    )
                  },
                },
              },
            }
          }
        }
      },
    )
  }

  else(_) {
    fail
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
  repaymentScriptHash: ByteArray,
) {
  expect Script(scriptHash) = differenceOutput.address.payment_credential
  expect InlineDatum(outputDatum) = differenceOutput.datum
  expect parsedDatum: RepaymentDatum = outputDatum

  let borrowerAsset =
    Asset { policyId: borrowerTokenPolicyId, assetName: borrowerAssetName }
  let newDatum =
    RepaymentDatumWithBond {
      action: "partial_liquidation",
      ownerAsset: borrowerAsset,
    }
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
      scriptHash == repaymentScriptHash,
      isDatumCorrect,
      length(flatten(differenceOutput.value)) <= 21,
    },
  }
}

fn validate_output_to_repayment(
  repaymentOutput: Output,
  loanAsset: Asset,
  repaymentAmount: Int,
  lenderAssetName: AssetName,
  action: ByteArray,
) {
  expect InlineDatum(outputDatum) = repaymentOutput.datum
  expect parsedDatum: RepaymentDatum = outputDatum

  let lenderAsset =
    Asset { policyId: lenderTokenPolicyId, assetName: lenderAssetName }
  let newDatum = RepaymentDatumWithBond { action, ownerAsset: lenderAsset }
  let isDatumCorrect = parsedDatum == newDatum
  let dosProtection = length(flatten(repaymentOutput.value)) <= 3
  and {
    is_output_to_sc(repaymentOutput, repaymentScriptHash),
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
  prevStakeCredential: Option<StakeCredential>,
  isCIP113: Bool,
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

  let toCorrectStaking = or {
      isCIP113 == True,
      activeLoanOutput.address.stake_credential == prevStakeCredential,
    }
  and {
    is_output_to_sc(activeLoanOutput, ownScriptHash),
    activeLoanOutput.value == loanValue,
    isDatumCorrect,
    toCorrectStaking,
  }
}

fn validate_output_to_active_loan_for_adding_collateral(
  activeLoanOutput: Output,
  datum: ActiveDatum,
  additionalCollateralAmount: Int,
  loanValue: Value,
  ownScriptHash: ByteArray,
  prevStakeCredential: Option<StakeCredential>,
  isCIP113: Bool,
) {
  expect InlineDatum(outputDatum) = activeLoanOutput.datum
  expect parsedDatum: ActiveDatum = outputDatum

  let correctValue =
    if datum.collateral.maybeAssetName == None {
      let oldCollateralTokens =
        quantity_of_policy_id(loanValue, datum.collateral.policyId)
      let newCollateralTokens =
        quantity_of_policy_id(activeLoanOutput.value, datum.collateral.policyId)
      //The Value must be the same as before except for the quantity of tokens with same collateral's policyId
      let sameValueWithoutCollateralTokens =
        value_without_policy_id_as_list(loanValue, datum.collateral.policyId) == value_without_policy_id_as_list(
          activeLoanOutput.value,
          datum.collateral.policyId,
        )
      let dosProtection = length(flatten(activeLoanOutput.value)) <= 21
      and {
        sameValueWithoutCollateralTokens,
        newCollateralTokens > oldCollateralTokens,
        dosProtection,
      }
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

  let toCorrectStaking = or {
      isCIP113 == True,
      activeLoanOutput.address.stake_credential == prevStakeCredential,
    }

  and {
    is_output_to_sc(activeLoanOutput, ownScriptHash),
    parsedDatum == datum,
    correctValue,
    toCorrectStaking,
  }
}

fn validate_output_to_active_loan_for_recasting(
  activeLoanOutput: Output,
  datum: ActiveDatum,
  principalPaid: Int,
  loanValue: Value,
  ownScriptHash: ByteArray,
  prevStakeCredential: Option<StakeCredential>,
  isCIP113: Bool,
) {
  expect InlineDatum(outputDatum) = activeLoanOutput.datum
  expect parsedDatum: ActiveDatum = outputDatum

  let newDatum =
    ActiveDatum {
      commonData: datum.commonData,
      borrowerAssetName: datum.borrowerAssetName,
      lenderAssetName: datum.lenderAssetName,
      collateral: datum.collateral,
      principalAmount: datum.principalAmount - principalPaid,
      principalDivider: datum.principalDivider,
      lendDate: datum.lendDate,
      repaidInstallments: datum.repaidInstallments,
      doneRecasts: datum.doneRecasts + 1,
    }

  let toCorrectStaking = or {
      isCIP113 == True,
      activeLoanOutput.address.stake_credential == prevStakeCredential,
    }
  and {
    is_output_to_sc(activeLoanOutput, ownScriptHash),
    parsedDatum == newDatum,
    activeLoanOutput.value == loanValue,
    toCorrectStaking,
  }
}

fn validate_output_to_dutch_auction(
  activeLoanInput: Input,
  borrower_bond_input: Input,
  dutchAuctionOutput: Output,
  validTo: Int,
) {
  todo
}
