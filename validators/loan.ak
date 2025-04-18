use aiken/collection/dict
use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use cardano/address.{Address, Credential, Script, StakeCredential}
use cardano/assets.{
  AssetName, PolicyId, Value, add, flatten, quantity_of, tokens,
}
use cardano/transaction.{InlineDatum, Input, Output, Transaction, Withdraw}
use fluidtokens/constants
use fluidtokens/finance.{
  can_liquidate, get_collateral_amount, get_equity, get_installment_amount,
  get_remaining_debt, is_recasting_permitted, is_repayment_late,
}
use fluidtokens/oracle.{retrieve_oracle_data}
use fluidtokens/types/config.{ConfigDatum}
use fluidtokens/types/dutch_auction.{DutchAuctionDatum}
use fluidtokens/types/general.{Asset, AuthorizationMethod, CollateralAsset}
use fluidtokens/types/loan.{
  ChangeCollateral, Claim, LoanDatum, LoanMintRedeemer, LoanWithdrawRedeemer,
  Recast, Repay,
} as l
use fluidtokens/types/oracle.{Aggregated, CommonFeedData} as oracle_type
use fluidtokens/types/pool.{
  Borrow, Liquidation, NoLiquidationDutchAuctionClaim,
  NoLiquidationFullCollateralClaim, PerpetualLoan, PoolWithdrawRedeemer,
}
use fluidtokens/types/repayment.{RepaymentDatum, RepaymentDatumWithToken}
use fluidtokens/types/request.{Lend, RequestWithdrawRedeemer}
use fluidtokens/utils.{
  is_nft_spent, is_output_to_spend_validator, quantity_of_policy_id,
  safe_list_at, value_without_policy_id_as_list,
}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
  is_output_to_smart_credential,
} as st_utils

validator loan(configNFTPolicyId: ByteArray, configNFTAssetName: ByteArray) {
  //Loan outputs are already checked by the pool validator, here we just ensure we don't mint additional undesired tokens
  //Burning is always allowed
  //Each output has a unique NFT
  mint(redeemer: LoanMintRedeemer, policy_id: PolicyId, self: Transaction) {
    let config =
      utils.get_config(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )

    let originInputs =
      if redeemer.isPoolOrigin {
        st_utils.get_inputs_from_smart_credential(
          self.inputs,
          Script(config.poolSpendScriptHash),
          Script(policy_id),
          config.smartTokensSpendScriptHash,
        )
      } else {
        st_utils.get_inputs_from_smart_credential(
          self.inputs,
          Script(config.requestSpendScriptHash),
          Script(policy_id),
          config.smartTokensSpendScriptHash,
        )
      }
    let loanOutputs =
      st_utils.get_outputs_to_smart_credential(
        self.outputs,
        Script(config.loanSpendScriptHash),
        Script(policy_id),
        config.smartTokensSpendScriptHash,
      )
    //We exclude the burnt tokens (quantity < 0) as they are always allowed
    let mintedNFTs =
      list.filter(
        dict.to_pairs(tokens(self.mint, policy_id)),
        fn(tokenPair) { tokenPair.2nd > 0 },
      )

    if list.length(mintedNFTs) > 0 {
      let expectedMintedNFTs =
        if redeemer.isPoolOrigin {
          let poolWithdrawRedeemer =
            safe_list_at(self.redeemers, redeemer.originWithdrawRedeemerIndex)
          expect
            poolWithdrawRedeemer.1st == Withdraw(Script(config.poolPolicyId))
          expect poolRedeemer: PoolWithdrawRedeemer = poolWithdrawRedeemer.2nd
          list.indexed_foldr(
            originInputs,
            [],
            fn(index, input, result) {
              let poolRedeemerAction =
                safe_list_at(poolRedeemer.actionsForEachInput, index)

              when poolRedeemerAction is {
                Borrow { .. } -> {
                  let loanAssetName =
                    utils.hash_output_ref(input.output_reference)
                  let loanOutput = safe_list_at(loanOutputs, index)
                  expect and {
                      dict.size(assets.tokens(loanOutput.value, policy_id)) == 1,
                      assets.quantity_of(
                        loanOutput.value,
                        policy_id,
                        loanAssetName,
                      ) == 1,
                    }
                  list.push(result, Pair(loanAssetName, 1))
                }
                _ -> result
              }
            },
          )
        } else {
          let requestWithdrawRedeemer =
            safe_list_at(self.redeemers, redeemer.originWithdrawRedeemerIndex)
          expect
            requestWithdrawRedeemer.1st == Withdraw(
              Script(config.requestPolicyId),
            )
          expect requestRedeemer: RequestWithdrawRedeemer =
            requestWithdrawRedeemer.2nd
          list.indexed_foldr(
            originInputs,
            [],
            fn(index, input, result) {
              let requestRedeemerAction =
                safe_list_at(requestRedeemer.actionsForEachInput, index)

              when requestRedeemerAction is {
                Lend { .. } -> {
                  let loanAssetName =
                    utils.hash_output_ref(input.output_reference)
                  let loanOutput = safe_list_at(loanOutputs, index)
                  expect and {
                      dict.size(assets.tokens(loanOutput.value, policy_id)) == 1,
                      assets.quantity_of(
                        loanOutput.value,
                        policy_id,
                        loanAssetName,
                      ) == 1,
                    }
                  list.push(result, Pair(loanAssetName, 1))
                }
                _ -> result
              }
            },
          )
        }

      list.sort(expectedMintedNFTs, utils.pairs_ordering) == mintedNFTs
    } else {
      True
    }
  }

  withdraw(
    redeemer: LoanWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(loanPolicyId) = credential
    let config =
      utils.get_config(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let loanInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(config.loanSpendScriptHash),
        credential,
        config.smartTokensSpendScriptHash,
      )

    //As we loop through the inputs we DO NOT need to ensure that the number of actions is equal to the number of inputs
    list.indexed_foldr(
      loanInputs,
      True,
      fn(index, input, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: LoanDatum = inputDatum
        let redeemerAction = safe_list_at(redeemer.actionsForEachInput, index)

        expect Some(interestRateAsRational) =
          rational.new(datum.commonData.interestRate, 1000)

        when redeemerAction is {
          Claim {
            liquidationMode,
            lenderBondInputIndex,
            borrowerBondRefInputIndex,
            collateralOracleRefInputIndex,
            principalOracleRefInputIndex,
            lenderAuth,
            equity,
            loanId,
          } -> {
            expect (Finite(validFrom), Finite(validTo)) =
              (
                self.validity_range.lower_bound.bound_type,
                self.validity_range.upper_bound.bound_type,
              )
            expect (Some(lenderBondInput), Some(borrowerBondInput)) =
              (
                list.at(self.inputs, lenderBondInputIndex),
                list.at(self.reference_inputs, borrowerBondRefInputIndex),
              )
            let isRepaymentLate =
              is_repayment_late(
                validFrom,
                datum.lendDate,
                datum.commonData.initialGracePeriod,
                datum.repaidInstallments,
                datum.commonData.installmentPeriod,
                datum.commonData.repaymentTimeWindow,
              )
            and {
              liquidationMode == datum.commonData.liquidationMode,
              quantity_of(input.output.value, loanPolicyId, loanId) == 1,
              quantity_of(self.mint, loanPolicyId, loanId) == -1,
              is_nft_spent(
                config.lenderBondPolicyId,
                datum.lenderAssetName,
                lenderBondInput,
              ),
              when datum.commonData.liquidationMode is {
                NoLiquidationFullCollateralClaim -> isRepaymentLate
                NoLiquidationDutchAuctionClaim -> {
                  expect Some(dutchAuctionOutput) =
                    list.at(
                      get_outputs_to_smart_credential(
                        self.outputs,
                        Script(config.dutchAuctionSpendScriptHash),
                        credential,
                        config.smartTokensSpendScriptHash,
                      ),
                      index,
                    )
                  let remainingDebt =
                    get_remaining_debt(
                      datum.commonData.repaymentMode,
                      rational.from_int(datum.principalAmount),
                      interestRateAsRational,
                      datum.commonData.totalInstallments,
                      datum.repaidInstallments,
                      datum.commonData.installmentPeriod,
                      datum.commonData.initialGracePeriod,
                      validFrom - datum.lendDate,
                    )
                  and {
                    isRepaymentLate,
                    validate_output_to_dutch_auction(
                      dutchAuctionOutput,
                      input,
                      borrowerBondInput.output.address,
                      validTo,
                      datum.collateral,
                      lenderAuth,
                      lenderBondInput.output.address,
                      datum.commonData.principalAsset,
                      remainingDebt,
                      config,
                    ),
                  }
                }
                Liquidation { lTV, lTVDivider, partialLiquidation } -> {
                  let principalAmountAsRational =
                    rational.from_int(datum.principalAmount)
                  expect Some(collateralOracleToken) =
                    datum.collateral.maybeOracleTokenAsset
                  let collateralOracleRefInput =
                    safe_list_at(
                      self.reference_inputs,
                      collateralOracleRefInputIndex,
                    )
                  expect Some(collateralOraclePriceFeed) =
                    retrieve_oracle_data(
                      collateralOracleRefInput.output.address.payment_credential,
                      collateralOracleRefInput.output.value,
                      self.redeemers,
                      validTo,
                      collateralOracleToken.policyId,
                      collateralOracleToken.assetName,
                      datum.collateral.policyId,
                      datum.collateral.maybeAssetName,
                    )
                  let principalOracleRefInput =
                    safe_list_at(
                      self.reference_inputs,
                      principalOracleRefInputIndex,
                    )
                  expect Some(principalOraclePriceFeed) =
                    if datum.commonData.principalAsset.policyId == "" {
                      Some(
                        Aggregated {
                          common: CommonFeedData {
                            valid_from: 0,
                            valid_to: 0,
                            token: Asset { policyId: "", assetName: "" },
                          },
                          token_price_in_lovelaces: 1,
                          token_price_denominator: 1,
                        },
                      )
                    } else {
                      retrieve_oracle_data(
                        principalOracleRefInput.output.address.payment_credential,
                        principalOracleRefInput.output.value,
                        self.redeemers,
                        validTo,
                        datum.commonData.principalOracleAsset.policyId,
                        datum.commonData.principalOracleAsset.assetName,
                        datum.commonData.principalAsset.policyId,
                        Some(datum.commonData.principalAsset.assetName),
                      )
                    }
                  let remainingDebt =
                    get_remaining_debt(
                      datum.commonData.repaymentMode,
                      principalAmountAsRational,
                      interestRateAsRational,
                      datum.commonData.totalInstallments,
                      datum.repaidInstallments,
                      datum.commonData.installmentPeriod,
                      datum.commonData.initialGracePeriod,
                      validFrom - datum.lendDate,
                    )
                  let collateralAmount =
                    get_collateral_amount(input.output.value, datum.collateral)
                  expect Some(ltvAsRational) = rational.new(lTV, lTVDivider)
                  and {
                    equity == get_equity(
                      collateralAmount,
                      rational.from_int(remainingDebt),
                      principalOraclePriceFeed,
                      collateralOraclePriceFeed,
                    ),
                    or {
                      isRepaymentLate,
                      can_liquidate(
                        principalAmountAsRational,
                        collateralAmount,
                        ltvAsRational,
                        principalOraclePriceFeed,
                        collateralOraclePriceFeed,
                      ),
                    },
                    or {
                      partialLiquidation == False,
                      equity <= 0,
                      {
                        expect Some(borrowerCompensationOutput) =
                          list.at(
                            get_outputs_to_smart_credential(
                              self.outputs,
                              Script(config.repaymentSpendScriptHash),
                              Script(config.repaymentPolicyId),
                              config.smartTokensSpendScriptHash,
                            ),
                            index,
                          )
                        equity_sent_to_borrower(
                          equityOutput: borrowerCompensationOutput,
                          equity: equity,
                          borrowerBondAsset: Asset {
                            policyId: config.borrowerBondPolicyId,
                            assetName: datum.borrowerAssetName,
                          },
                          principalAssetPolicyId: datum.commonData.principalAsset.policyId,
                          principalAssetName: datum.commonData.principalAsset.assetName,
                          repaymentPolicyId: config.repaymentPolicyId,
                          repaymentId: utils.hash_output_ref(
                            input.output_reference,
                          ),
                        )
                      },
                    },
                  }
                }
              },
            }
          }

          Repay { borrowerBondInputIndex, loanId, isFinalRepayment } -> {
            expect Finite(validFrom) =
              self.validity_range.lower_bound.bound_type
            expect Some(borrowerBondInput) =
              list.at(self.inputs, borrowerBondInputIndex)
            expect Some(repaymentOutput) =
              list.at(
                get_outputs_to_smart_credential(
                  self.outputs,
                  Script(config.repaymentSpendScriptHash),
                  Script(config.repaymentPolicyId),
                  config.smartTokensSpendScriptHash,
                ),
                index,
              )
            let isRepaymentLate =
              is_repayment_late(
                validFrom,
                datum.lendDate,
                datum.commonData.initialGracePeriod,
                datum.repaidInstallments,
                datum.commonData.installmentPeriod,
                datum.commonData.repaymentTimeWindow,
              )
            let isPerpetualLoanAndIsFinalRepayment =
              when datum.commonData.repaymentMode is {
                PerpetualLoan { .. } -> isFinalRepayment
                _ -> False
              }
            let nextRepaymentAmount =
              if isPerpetualLoanAndIsFinalRepayment {
                get_remaining_debt(
                  datum.commonData.repaymentMode,
                  rational.from_int(datum.principalAmount),
                  interestRateAsRational,
                  datum.commonData.totalInstallments,
                  datum.repaidInstallments,
                  datum.commonData.installmentPeriod,
                  datum.commonData.initialGracePeriod,
                  validFrom - datum.lendDate,
                )
              } else {
                get_installment_amount(
                  datum.commonData.repaymentMode,
                  rational.from_int(datum.principalAmount),
                  interestRateAsRational,
                  datum.commonData.totalInstallments,
                  datum.repaidInstallments,
                  datum.commonData.installmentPeriod,
                  datum.commonData.initialGracePeriod,
                  isRepaymentLate,
                  datum.commonData.penaltyFeeForLateRepayment,
                )
              }
            and {
              quantity_of(input.output.value, loanPolicyId, loanId) == 1,
              is_nft_spent(
                config.borrowerBondPolicyId,
                datum.borrowerAssetName,
                borrowerBondInput,
              ),
              validate_output_to_repayment(
                repaymentOutput: repaymentOutput,
                loanAsset: datum.commonData.principalAsset,
                repaymentAmount: nextRepaymentAmount,
                lenderBondAsset: Asset {
                  policyId: config.lenderBondPolicyId,
                  assetName: datum.lenderAssetName,
                },
                action: constants.repayment_action_installment,
                extra_data: (loanId, datum.repaidInstallments + 1),
                repaymentPolicyId: config.repaymentPolicyId,
                repaymentId: utils.hash_output_ref(input.output_reference),
              ),
              or {
                and {
                  or {
                    isPerpetualLoanAndIsFinalRepayment,
                    datum.repaidInstallments == datum.commonData.totalInstallments - 1,
                  },
                  quantity_of(self.mint, loanPolicyId, loanId) == -1,
                },
                {
                  let loanOutput =
                    safe_list_at(
                      get_outputs_to_smart_credential(
                        self.outputs,
                        Script(config.loanSpendScriptHash),
                        credential,
                        config.smartTokensSpendScriptHash,
                      ),
                      index,
                    )
                  validate_eventual_output_to_loan_for_repayment(
                    loanOutput,
                    datum,
                    input.output.value == loanOutput.value,
                    input.output.address.stake_credential,
                    config.loanSpendScriptHash,
                  )
                },
              },
            }
          }
          ChangeCollateral {
            borrowerBondInputIndex,
            newCollateralAmount,
            loanId,
            collateralOracleRefInputIndex,
            principalOracleRefInputIndex,
          } ->
            when datum.commonData.liquidationMode is {
              Liquidation { lTV, lTVDivider, .. } -> {
                expect Finite(validTo) =
                  self.validity_range.upper_bound.bound_type
                expect Some(borrowerBondInput) =
                  list.at(self.inputs, borrowerBondInputIndex)
                expect Some(loanOutput) =
                  list.at(
                    get_outputs_to_smart_credential(
                      self.outputs,
                      Script(config.loanSpendScriptHash),
                      credential,
                      config.smartTokensSpendScriptHash,
                    ),
                    index,
                  )
                let principalAmountAsRational =
                  rational.from_int(datum.principalAmount)
                expect Some(ltvAsRational) = rational.new(lTV, lTVDivider)
                expect Some(collateralOracleToken) =
                  datum.collateral.maybeOracleTokenAsset
                let collateralOracleRefInput =
                  safe_list_at(
                    self.reference_inputs,
                    collateralOracleRefInputIndex,
                  )
                expect Some(collateralOraclePriceFeed) =
                  retrieve_oracle_data(
                    collateralOracleRefInput.output.address.payment_credential,
                    collateralOracleRefInput.output.value,
                    self.redeemers,
                    validTo,
                    collateralOracleToken.policyId,
                    collateralOracleToken.assetName,
                    datum.collateral.policyId,
                    datum.collateral.maybeAssetName,
                  )
                let principalOracleRefInput =
                  safe_list_at(
                    self.reference_inputs,
                    principalOracleRefInputIndex,
                  )
                expect Some(principalOraclePriceFeed) =
                  if datum.commonData.principalAsset.policyId == "" {
                    Some(
                      Aggregated {
                        common: CommonFeedData {
                          valid_from: 0,
                          valid_to: 0,
                          token: Asset { policyId: "", assetName: "" },
                        },
                        token_price_in_lovelaces: 1,
                        token_price_denominator: 1,
                      },
                    )
                  } else {
                    retrieve_oracle_data(
                      principalOracleRefInput.output.address.payment_credential,
                      principalOracleRefInput.output.value,
                      self.redeemers,
                      validTo,
                      datum.commonData.principalOracleAsset.policyId,
                      datum.commonData.principalOracleAsset.assetName,
                      datum.commonData.principalAsset.policyId,
                      Some(datum.commonData.principalAsset.assetName),
                    )
                  }
                and {
                  quantity_of(input.output.value, loanPolicyId, loanId) == 1,
                  is_nft_spent(
                    config.borrowerBondPolicyId,
                    datum.borrowerAssetName,
                    borrowerBondInput,
                  ),
                  can_liquidate(
                    principalAmountAsRational,
                    rational.from_int(newCollateralAmount),
                    ltvAsRational,
                    principalOraclePriceFeed,
                    collateralOraclePriceFeed,
                  ) == False,
                  validate_output_to_loan_for_changing_collateral(
                    loanOutput,
                    datum,
                    newCollateralAmount,
                    input.output.value,
                    input.output.address.stake_credential,
                    config.loanSpendScriptHash,
                  ),
                }
              }
              _ -> False
            }
          Recast { borrowerBondInputIndex, principalPaid, loanId } -> {
            expect Finite(validFrom) =
              self.validity_range.lower_bound.bound_type
            expect Some(borrowerBondInput) =
              list.at(self.inputs, borrowerBondInputIndex)
            expect Some(repaymentOutput) =
              list.at(
                get_outputs_to_smart_credential(
                  self.outputs,
                  Script(config.repaymentSpendScriptHash),
                  Script(config.repaymentPolicyId),
                  config.smartTokensSpendScriptHash,
                ),
                index,
              )
            let debtAfterRecasting =
              get_remaining_debt(
                datum.commonData.repaymentMode,
                rational.from_int(datum.principalAmount - principalPaid),
                interestRateAsRational,
                datum.commonData.totalInstallments,
                datum.repaidInstallments,
                datum.commonData.installmentPeriod,
                datum.commonData.initialGracePeriod,
                validFrom - datum.lendDate,
              )
            and {
              principalPaid > 0,
              quantity_of(input.output.value, loanPolicyId, loanId) == 1,
              is_nft_spent(
                config.borrowerBondPolicyId,
                datum.borrowerAssetName,
                borrowerBondInput,
              ),
              is_recasting_permitted(
                datum.commonData.repaymentMode,
                datum.doneRecasts,
              ),
              validate_output_to_repayment(
                repaymentOutput: repaymentOutput,
                loanAsset: datum.commonData.principalAsset,
                repaymentAmount: principalPaid,
                lenderBondAsset: Asset {
                  policyId: config.lenderBondPolicyId,
                  assetName: datum.lenderAssetName,
                },
                action: constants.repayment_action_recast,
                extra_data: loanId,
                repaymentPolicyId: config.repaymentPolicyId,
                repaymentId: utils.hash_output_ref(input.output_reference),
              ),
              or {
                and {
                  debtAfterRecasting == 0,
                  quantity_of(self.mint, loanPolicyId, loanId) == -1,
                },
                and {
                  debtAfterRecasting > 0,
                  {
                    let loanOutput =
                      safe_list_at(
                        get_outputs_to_smart_credential(
                          self.outputs,
                          Script(config.loanSpendScriptHash),
                          credential,
                          config.smartTokensSpendScriptHash,
                        ),
                        index,
                      )
                    validate_eventual_output_to_loan_for_recasting(
                      loanOutput,
                      datum,
                      principalPaid,
                      input.output.value == loanOutput.value,
                      input.output.address.stake_credential,
                      config.loanSpendScriptHash,
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

fn equity_sent_to_borrower(
  equityOutput: Output,
  equity: Int,
  borrowerBondAsset: Asset,
  principalAssetPolicyId: ByteArray,
  principalAssetName: AssetName,
  repaymentPolicyId: ByteArray,
  repaymentId: ByteArray,
) {
  expect InlineDatum(outputDatum) = equityOutput.datum
  expect parsedDatum: RepaymentDatum = outputDatum
  let newDatum =
    RepaymentDatumWithToken {
      action: constants.repayment_action_partial_liquidation,
      data: None,
      ownerAsset: borrowerBondAsset,
    }

  let containsCorrectAmount =
    quantity_of(equityOutput.value, principalAssetPolicyId, principalAssetName) == equity

  let isDatumCorrect = parsedDatum == newDatum
  let containsRepaymentNFT =
    quantity_of(equityOutput.value, repaymentPolicyId, repaymentId) == 1
  let dosProtection =
    if principalAssetPolicyId == "" {
      length(flatten(equityOutput.value)) <= 2
    } else {
      length(flatten(equityOutput.value)) <= 3
    }
  and {
    //No staking check here
    isDatumCorrect,
    containsRepaymentNFT,
    containsCorrectAmount,
    dosProtection,
  }
}

fn validate_output_to_repayment(
  repaymentOutput: Output,
  loanAsset: Asset,
  repaymentAmount: Int,
  lenderBondAsset: Asset,
  action: ByteArray,
  extra_data: Data,
  repaymentPolicyId: ByteArray,
  repaymentId: ByteArray,
) {
  expect InlineDatum(outputDatum) = repaymentOutput.datum
  expect parsedDatum: RepaymentDatum = outputDatum
  let newDatum =
    RepaymentDatumWithToken {
      action,
      data: extra_data,
      ownerAsset: lenderBondAsset,
    }
  let containsCorrectAmount =
    quantity_of(repaymentOutput.value, loanAsset.policyId, loanAsset.assetName) >= repaymentAmount
  let containsRepaymentNFT =
    quantity_of(repaymentOutput.value, repaymentPolicyId, repaymentId) == 1
  let isDatumCorrect = parsedDatum == newDatum
  let dosProtection =
    if loanAsset.policyId == "" {
      length(flatten(repaymentOutput.value)) <= 2
    } else {
      length(flatten(repaymentOutput.value)) <= 3
    }
  and {
    //No staking check here
    isDatumCorrect,
    containsRepaymentNFT,
    containsCorrectAmount,
    dosProtection,
  }
}

fn validate_eventual_output_to_loan_for_repayment(
  loanOutput: Output,
  datum: LoanDatum,
  outputValueSameOfInputValue: Bool,
  prevStakeCredential: Option<StakeCredential>,
  loanSpendScriptHash: ByteArray,
) {
  expect InlineDatum(outputDatum) = loanOutput.datum
  expect parsedDatum: LoanDatum = outputDatum

  let newDatum =
    LoanDatum {
      commonData: datum.commonData,
      originAssetName: datum.originAssetName,
      borrowerAssetName: datum.borrowerAssetName,
      lenderAssetName: datum.lenderAssetName,
      collateral: datum.collateral,
      principalAmount: datum.principalAmount,
      lendDate: datum.lendDate,
      repaidInstallments: datum.repaidInstallments + 1,
      doneRecasts: datum.doneRecasts,
    }
  let isDatumCorrect = parsedDatum == newDatum

  let correctDestination =
    if is_output_to_spend_validator(loanOutput, loanSpendScriptHash) {
      loanOutput.address.stake_credential == prevStakeCredential
    } else {
      //outputs have been already filtered at the beginning
      True
    }
  and {
    correctDestination,
    isDatumCorrect,
    //loanNFT is already included in the value
    outputValueSameOfInputValue,
  }
}

fn validate_output_to_loan_for_changing_collateral(
  loanOutput: Output,
  datum: LoanDatum,
  newCollateralAmount: Int,
  loanValue: Value,
  prevStakeCredential: Option<StakeCredential>,
  loanSpendScriptHash: ByteArray,
) {
  expect InlineDatum(outputDatum) = loanOutput.datum
  expect parsedDatum: LoanDatum = outputDatum

  let correctValue =
    if datum.collateral.maybeAssetName == None {
      let newCollateralTokens =
        quantity_of_policy_id(loanOutput.value, datum.collateral.policyId)
      //The Value must be the same as before except for the quantity of tokens with same collateral's policyId
      let sameValueWithoutCollateralTokens =
        value_without_policy_id_as_list(loanValue, datum.collateral.policyId) == value_without_policy_id_as_list(
          loanOutput.value,
          datum.collateral.policyId,
        )
      let dosProtection =
        if datum.collateral.policyId == "" {
          length(flatten(loanValue)) <= 2
        } else {
          length(flatten(loanValue)) <= 3
        }
      and {
        sameValueWithoutCollateralTokens,
        newCollateralTokens == newCollateralAmount,
        dosProtection,
      }
    } else {
      expect Some(assetName) = datum.collateral.maybeAssetName
      //As there is no simple way to forcefully set a token amount in a Value, 
      //we substract the current amount (resulting it as 0) and add the new one
      let expectedValue =
        add(
          loanValue,
          datum.collateral.policyId,
          assetName,
          -quantity_of(loanValue, datum.collateral.policyId, assetName) + newCollateralAmount,
        )
      loanOutput.value == expectedValue
    }

  let correctDestination =
    if is_output_to_spend_validator(loanOutput, loanSpendScriptHash) {
      loanOutput.address.stake_credential == prevStakeCredential
    } else {
      //outputs have been already filtered at the beginning
      True
    }

  and {
    correctDestination,
    parsedDatum == datum,
    //loanNFT is already included in the value
    correctValue,
  }
}

fn validate_eventual_output_to_loan_for_recasting(
  loanOutput: Output,
  datum: LoanDatum,
  principalPaid: Int,
  outputValueSameOfInputValue: Bool,
  prevStakeCredential: Option<StakeCredential>,
  loanSpendScriptHash: ByteArray,
) {
  expect InlineDatum(outputDatum) = loanOutput.datum
  expect parsedDatum: LoanDatum = outputDatum

  let newDatum =
    LoanDatum {
      commonData: datum.commonData,
      originAssetName: datum.originAssetName,
      borrowerAssetName: datum.borrowerAssetName,
      lenderAssetName: datum.lenderAssetName,
      collateral: datum.collateral,
      principalAmount: datum.principalAmount - principalPaid,
      lendDate: datum.lendDate,
      repaidInstallments: datum.repaidInstallments,
      doneRecasts: datum.doneRecasts + 1,
    }

  let correctDestination =
    if is_output_to_spend_validator(loanOutput, loanSpendScriptHash) {
      loanOutput.address.stake_credential == prevStakeCredential
    } else {
      //outputs have been already filtered at the beginning
      True
    }

  and {
    correctDestination,
    parsedDatum == newDatum,
    //loanNFT is already included in the value
    outputValueSameOfInputValue,
  }
}

fn validate_output_to_dutch_auction(
  dutchAuctionOutput: Output,
  loanInput: Input,
  borrowerAddress: Address,
  validTo: Int,
  collateral: CollateralAsset,
  lenderAuth: AuthorizationMethod,
  lenderAddress: Address,
  principalAsset: Asset,
  remainingDebt: Int,
  config: ConfigDatum,
) {
  expect InlineDatum(outputDatum) = dutchAuctionOutput.datum
  expect parsedDatum: DutchAuctionDatum = outputDatum

  let newDatum =
    DutchAuctionDatum {
      ownerAuth: lenderAuth,
      ownerAddress: lenderAddress,
      currency: principalAsset,
      startingPrice: remainingDebt * config.dutchAuctionStartingIncreasePerMille / 1000,
      loweringAmount: config.dutchAuctionLoweringAmount,
      loweringFrequency: config.dutchAuctionLoweringFrequency,
      minPriceToCancel: config.dutchAuctionMinPriceToCancel,
      startDate: validTo,
      borrowerAddress: Some(borrowerAddress),
      debtAmount: remainingDebt,
    }
  let isDatumCorrect = parsedDatum == newDatum

  let correctValue =
    if collateral.maybeAssetName == None {
      quantity_of_policy_id(dutchAuctionOutput.value, collateral.policyId) == quantity_of_policy_id(
        loanInput.output.value,
        collateral.policyId,
      )
    } else {
      expect Some(assetName) = collateral.maybeAssetName
      quantity_of(dutchAuctionOutput.value, collateral.policyId, assetName) == quantity_of(
        loanInput.output.value,
        collateral.policyId,
        assetName,
      )
    }

  let dosProtection =
    if collateral.policyId == "" {
      length(flatten(dutchAuctionOutput.value)) <= 2
    } else {
      length(flatten(dutchAuctionOutput.value)) <= 3
    }
  and {
    is_output_to_smart_credential(
      dutchAuctionOutput,
      Script(config.dutchAuctionSpendScriptHash),
      Script(config.dutchAuctionWithdrawScriptHash),
      None,
      config.smartTokensSpendScriptHash,
    ),
    isDatumCorrect,
    correctValue,
    dosProtection,
  }
}
