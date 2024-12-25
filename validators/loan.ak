use aiken/collection/dict
use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use aiken/option
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Script, StakeCredential}
use cardano/assets.{
  AssetName, PolicyId, Value, add, flatten, quantity_of, tokens,
}
use cardano/transaction.{
  InlineDatum, Input, Output, Transaction, Withdraw, find_input,
}
use fluidtokens/constants
use fluidtokens/finance.{
  can_liquidate, get_collateral_value_in_principal_currency,
  get_installment_amount, get_remaining_debt, is_recasting_permitted,
  is_repayment_late,
}
use fluidtokens/oracle.{retrieve_oracle_data, validate_oracle_ref_input_value}
use fluidtokens/types/datum.{
  ConfigDatum, DutchAuctionDatum, Liquidation, LoanDatum,
  NoLiquidationDutchAuctionClaim, NoLiquidationFullCollateralClaim,
  RepaymentDatum, RepaymentDatumWithToken,
}
use fluidtokens/types/general.{Asset, CollateralAsset}
use fluidtokens/types/redeemer.{
  AddCollateral, Borrow, Claim, LoanMintRedeemer, LoanWithdrawRedeemer,
  PoolWithdrawRedeemer, Recast, Repay,
}
use fluidtokens/utils.{
  get_inputs_from_sc, get_outputs_to_sc, is_nft_spent,
  is_output_to_spend_validator, quantity_of_policy_id, safe_list_at,
  value_without_policy_id_as_list,
}

validator loan(configAsset: Asset) {
  //Loan outputs are already checked by the pool validator, here we just ensure we don't mint additional undesired tokens
  //Burning is always allowed
  //Each output has a unique NFT
  mint(redeemer: LoanMintRedeemer, policy_id: PolicyId, self: Transaction) {
    let config =
      utils.get_config(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configAsset.policyId,
        configAsset.assetName,
      )

    let inputRefHash = utils.hash_output_ref(redeemer.inputRef)
    let loanOutputs =
      utils.get_outputs_to_sc(
        self.outputs,
        config.loanSpendScriptHash,
        config.smartTokensSpendScriptHash,
      )
    let isInputRefSpent =
      option.is_some(find_input(self.inputs, redeemer.inputRef))
    let mintedNFTs = dict.to_pairs(tokens(self.mint, policy_id))

    let poolWithdrawRedeemer =
      safe_list_at(self.redeemers, redeemer.poolWithdrawRedeemerIndex)
    expect poolWithdrawRedeemer.1st == Withdraw(Script(config.poolPolicyId))
    expect poolRedeemer: PoolWithdrawRedeemer = poolWithdrawRedeemer.2nd

    let expectedMintedNFTs =
      list.indexed_foldr(
        list.filter(
          poolRedeemer.actionsForEachInput,
          fn(action) {
            when action is {
              Borrow { .. } -> True
              _ -> False
            }
          },
        ),
        [],
        fn(index, _action, result) {
          let loanAssetName =
            bytearray.push(bytearray.drop(inputRefHash, 1), index)
          expect Some(output) = list.at(loanOutputs, index)
          expect and {
              dict.size(assets.tokens(output.value, policy_id)) == 1,
              assets.quantity_of(output.value, policy_id, loanAssetName) == 1,
            }
          list.push(result, Pair(loanAssetName, 1))
        },
      )

    and {
      isInputRefSpent,
      expectedMintedNFTs == mintedNFTs,
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
        configAsset.policyId,
        configAsset.assetName,
      )
    let loanInputs =
      get_inputs_from_sc(
        self.inputs,
        config.loanSpendScriptHash,
        config.smartTokensSpendScriptHash,
      )

    and {
      //Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
      length(loanInputs) == length(redeemer.actionsForEachInput),
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

          when redeemerAction is {
            Claim(
              liquidationMode,
              lenderBondInputIndex,
              collateralOracleRefInputIndex,
              lenderAuthHash,
              lenderAddress,
              equity,
              loanId,
            ) -> {
              expect (Finite(validFrom), Finite(validTo)) =
                (
                  self.validity_range.lower_bound.bound_type,
                  self.validity_range.upper_bound.bound_type,
                )
              expect Some(lenderBondInput) =
                list.at(self.inputs, lenderBondInputIndex)
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
                        get_outputs_to_sc(
                          self.outputs,
                          config.ducthAuctionSpendScriptHash,
                          config.smartTokensSpendScriptHash,
                        ),
                        index,
                      )
                    let remainingDebt =
                      get_remaining_debt(
                        datum.commonData.repaymentMode,
                        datum.principalAmount,
                        datum.principalDivider,
                        datum.commonData.interestRate,
                        datum.commonData.totalInstallments,
                        datum.repaidInstallments,
                      )
                    and {
                      isRepaymentLate,
                      validate_output_to_dutch_auction(
                        dutchAuctionOutput,
                        input,
                        lenderBondInput,
                        validTo,
                        datum.collateral,
                        lenderAuthHash,
                        lenderAddress,
                        datum.commonData.principalAsset,
                        remainingDebt,
                        config,
                      ),
                    }
                  }
                  Liquidation(lTV, lTVDivider, partialLiquidation) -> {
                    let oracleRefInput =
                      safe_list_at(
                        self.reference_inputs,
                        collateralOracleRefInputIndex,
                      )
                    expect Some(oraclePriceFeed) =
                      retrieve_oracle_data(
                        oracleRefInput.output.address.payment_credential,
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
                    let remainingDebt =
                      get_remaining_debt(
                        datum.commonData.repaymentMode,
                        datum.principalAmount,
                        datum.principalDivider,
                        datum.commonData.interestRate,
                        datum.commonData.totalInstallments,
                        datum.repaidInstallments,
                      )
                    expect Some(repaymentOutput) =
                      list.at(
                        get_outputs_to_sc(
                          self.outputs,
                          config.repaymentSpendScriptHash,
                          config.smartTokensSpendScriptHash,
                        ),
                        index,
                      )
                    and {
                      equity == collateralValueInPrincipalCurrency - remainingDebt,
                      validate_oracle_ref_input_value(
                        oracleRefInput.output.value,
                        datum.collateral,
                      ),
                      or {
                        isRepaymentLate,
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
                        equity <= 0,
                        equity_sent_to_borrower(
                          equityOutput: repaymentOutput,
                          equity: equity,
                          borrowerBondAsset: Asset {
                            policyId: config.borrowerBondPolicyId,
                            assetName: datum.borrowerAssetName,
                          },
                          principalAssetPolicyId: datum.commonData.principalAsset.policyId,
                          principalAssetName: datum.commonData.principalAsset.assetName,
                          repaymentPolicyId: config.repaymentPolicyId,
                          repaymentId: loanId,
                        ),
                      },
                    }
                  }
                },
              }
            }

            Repay(borrowerBondInputIndex, loanId) -> {
              expect Finite(validFrom) =
                self.validity_range.lower_bound.bound_type
              expect Some(borrowerBondInput) =
                list.at(self.inputs, borrowerBondInputIndex)
              expect Some(repaymentOutput) =
                list.at(
                  get_outputs_to_sc(
                    self.outputs,
                    config.repaymentSpendScriptHash,
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
              let nextRepaymentAmount =
                get_installment_amount(
                  datum.commonData.repaymentMode,
                  datum.principalAmount,
                  datum.principalDivider,
                  datum.commonData.interestRate,
                  datum.commonData.totalInstallments,
                  isRepaymentLate,
                  datum.commonData.penaltyFeeForLateRepayment,
                )
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
                  repaymentId: loanId,
                ),
                or {
                  and {
                    datum.repaidInstallments == datum.commonData.totalInstallments - 1,
                    quantity_of(self.mint, loanPolicyId, loanId) == -1,
                  },
                  {
                    let loanOutput =
                      safe_list_at(
                        get_outputs_to_sc(
                          self.outputs,
                          config.loanSpendScriptHash,
                          config.smartTokensSpendScriptHash,
                        ),
                        index,
                      )
                    validate_eventual_output_to_loan_for_repayment(
                      loanOutput,
                      datum,
                      datum.repaidInstallments + 1,
                      input.output.value == loanOutput.value,
                      input.output.address.stake_credential,
                      config.loanSpendScriptHash,
                    )
                  },
                },
              }
            }
            AddCollateral(borrowerBondInputIndex, addedCollateralAmount, loanId) -> {
              expect Some(borrowerBondInput) =
                list.at(self.inputs, borrowerBondInputIndex)
              expect Some(loanOutput) =
                list.at(
                  get_outputs_to_sc(
                    self.outputs,
                    config.loanSpendScriptHash,
                    config.smartTokensSpendScriptHash,
                  ),
                  index,
                )
              and {
                addedCollateralAmount > 0,
                quantity_of(input.output.value, loanPolicyId, loanId) == 1,
                is_nft_spent(
                  config.borrowerBondPolicyId,
                  datum.borrowerAssetName,
                  borrowerBondInput,
                ),
                validate_output_to_loan_for_adding_collateral(
                  loanOutput,
                  datum,
                  addedCollateralAmount,
                  input.output.value,
                  input.output.address.stake_credential,
                  config.loanSpendScriptHash,
                ),
              }
            }
            Recast(borrowerBondInputIndex, principalPaid, loanId) -> {
              expect Some(borrowerBondInput) =
                list.at(self.inputs, borrowerBondInputIndex)
              expect Some(repaymentOutput) =
                list.at(
                  get_outputs_to_sc(
                    self.outputs,
                    config.repaymentSpendScriptHash,
                    config.smartTokensSpendScriptHash,
                  ),
                  index,
                )
              let debtAfterRecasting =
                get_remaining_debt(
                  datum.commonData.repaymentMode,
                  datum.principalAmount - principalPaid,
                  datum.principalDivider,
                  datum.commonData.interestRate,
                  datum.commonData.totalInstallments,
                  datum.repaidInstallments,
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
                  repaymentId: loanId,
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
                          get_outputs_to_sc(
                            self.outputs,
                            config.loanSpendScriptHash,
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
      ),
    }
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
  let dosProtection = length(flatten(equityOutput.value)) <= 21
  and {
    //TODO No staking check here, right?
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
  let dosProtection = length(flatten(repaymentOutput.value)) <= 3
  and {
    //TODO No staking check here, right?
    isDatumCorrect,
    containsRepaymentNFT,
    containsCorrectAmount,
    dosProtection,
  }
}

fn validate_eventual_output_to_loan_for_repayment(
  loanOutput: Output,
  datum: LoanDatum,
  newRepaidInstallments: Int,
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
      principalDivider: datum.principalDivider,
      lendDate: datum.lendDate,
      repaidInstallments: newRepaidInstallments,
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

fn validate_output_to_loan_for_adding_collateral(
  loanOutput: Output,
  datum: LoanDatum,
  additionalCollateralAmount: Int,
  loanValue: Value,
  prevStakeCredential: Option<StakeCredential>,
  loanSpendScriptHash: ByteArray,
) {
  expect InlineDatum(outputDatum) = loanOutput.datum
  expect parsedDatum: LoanDatum = outputDatum

  let correctValue =
    if datum.collateral.maybeAssetName == None {
      let oldCollateralTokens =
        quantity_of_policy_id(loanValue, datum.collateral.policyId)
      let newCollateralTokens =
        quantity_of_policy_id(loanOutput.value, datum.collateral.policyId)
      //The Value must be the same as before except for the quantity of tokens with same collateral's policyId
      let sameValueWithoutCollateralTokens =
        value_without_policy_id_as_list(loanValue, datum.collateral.policyId) == value_without_policy_id_as_list(
          loanOutput.value,
          datum.collateral.policyId,
        )
      let dosProtection = length(flatten(loanOutput.value)) <= 21
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
      principalDivider: datum.principalDivider,
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
  borrowerBondInput: Input,
  validTo: Int,
  collateral: CollateralAsset,
  lenderAuthHash: ByteArray,
  lenderAddress: Address,
  principalAsset: Asset,
  remainingDebt: Int,
  config: ConfigDatum,
) {
  expect InlineDatum(outputDatum) = dutchAuctionOutput.datum
  expect parsedDatum: DutchAuctionDatum = outputDatum
  let borrowerAddress = borrowerBondInput.output.address

  let newDatum =
    DutchAuctionDatum {
      ownerAuthHash: lenderAuthHash,
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

  let dosProtection = length(flatten(dutchAuctionOutput.value)) <= 21
  and {
    is_output_to_spend_validator(
      dutchAuctionOutput,
      config.ducthAuctionSpendScriptHash,
    ),
    //TODO No staking check here, right?
    isDatumCorrect,
    correctValue,
    dosProtection,
  }
}
