use aiken/collection/list.{length}
use aiken/crypto.{sha2_256}
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Script}
use cardano/assets.{AssetName, Value, flatten, quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use types/datum.{
  ActiveDatum, DutchAuctionDatum, InterestOnRemainingPrincipal, Liquidation,
  NoLiquidationDutchAuctionClaim, NoLiquidationFullCollateralClaim, PoolDatum,
  PrincipalAndInterestOnInstallments, RepaymentDatum, RepaymentMode,
}
use types/general.{Asset, CollateralAsset}
use types/redeemer.{
  ActiveWithdrawRedeemer, AddCollateral, Aggregated, Dedicated, Liquidate,
  OraclePriceFeed, PoolAction, PoolSpendRedeemer, Pooled, Recast, Repay,
}
use utils.{
  address_in_signatures, authorize_action, get_inputs_from_sc, get_outputs_to_sc,
  get_own_hash, is_nft_spent, is_output_to_sc, quantity_of_policy_id,
  retrieve_oracle_data, safe_list_at, token_b_needed_to_purchase_token_a,
  validity_range_within_an_hour,
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

        when redeemerAction is {
          Liquidate(bondInputIndex) -> {
            expect Some(actualBondInput) = list.at(self.inputs, bondInputIndex)
            and {
              is_nft_spent(
                lenderTokenPolicyId,
                datum.lenderAssetName,
                actualBondInput,
              ),
              when datum.commonData.liquidationMode is {
                NoLiquidationFullCollateralClaim ->
                  is_it_after_deadline(
                    validFrom,
                    datum.lendDate,
                    datum.commonData.initialGracePeriod,
                    datum.repaidInstallments,
                    datum.commonData.totalInstallments,
                    datum.commonData.duration,
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
                    is_it_after_deadline(
                      validFrom,
                      datum.lendDate,
                      datum.commonData.initialGracePeriod,
                      datum.repaidInstallments,
                      datum.commonData.totalInstallments,
                      datum.commonData.duration,
                    ),
                    correct_output_to_dutch_auction(
                      input,
                      actualBondInput,
                      dutchAuctionOutput,
                      validTo,
                    ),
                  }
                }
                Liquidation(lTV, lTVDivider, authHash) -> {
                  //TODO IS THIS CORRECT?
                  expect Some(borrowerOutput) = list.at(self.outputs, index)

                  and {
                    can_liquidate(
                      validFrom,
                      datum.lendDate,
                      datum.commonData.initialGracePeriod,
                      datum.repaidInstallments,
                      datum.commonData.totalInstallments,
                      datum.commonData.duration,
                    ),
                    difference_sent_to_borrower(
                      //TODO
                      0,
                      get_remaining_debt(
                        datum.commonData.repaymentMode,
                        datum.collateral,
                        datum.principalAmount,
                        datum.principalDivider,
                        datum.commonData.interestRate,
                        datum.commonData.totalInstallments,
                        datum.repaidInstallments,
                      ),
                      actualBondInput,
                      borrowerOutput,
                    ),
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
                datum.collateral,
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

fn is_it_after_deadline(
  validFrom: Int,
  lendDate: Int,
  initialGracePeriod: Int,
  repaidInstallments: Int,
  totalInstallments: Int,
  loanDuration: Int,
) {
  let relativeMaxTimeForNextInstallment =
    ( repaidInstallments + 1 ) * loanDuration / totalInstallments
  validFrom > lendDate + initialGracePeriod + relativeMaxTimeForNextInstallment
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
  validFrom: Int,
  lendDate: Int,
  initialGracePeriod: Int,
  repaidInstallments: Int,
  totalInstallments: Int,
  loanDuration: Int,
) {
  todo
}

fn difference_sent_to_borrower(
  collateralAdaValue: Int,
  totalDebtInAda: Int,
  borrower_bond_input: Input,
  borrowerOutput: Output,
) {
  let borrowerAddress = borrower_bond_input.output.address
  or {
    collateralAdaValue - totalDebtInAda < 0,
    and {
      quantity_of(borrowerOutput.value, "", "") >= collateralAdaValue - totalDebtInAda,
      borrowerOutput.address == borrowerAddress,
      length(flatten(borrowerOutput.value)) <= 21,
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

//TODO Use rational library?
fn get_remaining_debt(
  repaymentMode: RepaymentMode,
  collateral: CollateralAsset,
  principal: Int,
  principalDivider: Int,
  interestRate: Int,
  totalInstallments: Int,
  repaidInstallments: Int,
) {
  when repaymentMode is {
    InterestOnRemainingPrincipal(..) -> todo
    PrincipalAndInterestOnInstallments ->
      if collateral.maybeOracleTokenAsset == None {
        let totalInterest = principal * interestRate / 1000
        let singleInstallmentAmount =
          ( principal + totalInterest ) / totalInstallments
        principal + totalInterest - repaidInstallments * singleInstallmentAmount
      } else {
        todo
      }
  }
}
