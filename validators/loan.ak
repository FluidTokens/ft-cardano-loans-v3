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
use finance.{
  can_liquidate, get_collateral_value_in_principal_currency, get_remaining_debt,
  get_repayment_amount, is_recasting_permitted, is_repayment_late,
}
use types/datum.{
  ConfigDatum, DutchAuctionDatum, Liquidation, LoanDatum,
  NoLiquidationDutchAuctionClaim, NoLiquidationFullCollateralClaim,
  RepaymentDatum, RepaymentDatumWithToken,
}
use types/general.{Asset, CollateralAsset}
use types/redeemer.{
  AddCollateral, Borrow, Claim, LoanMintRedeemer, LoanWithdrawRedeemer,
  PoolWithdrawRedeemer, Recast, Repay,
}
use utils.{
  get_inputs_from_sc_or_delegated_to_sc, get_outputs_to_sc_or_delegated_to_sc,
  is_nft_spent, is_output_to_sc, quantity_of_policy_id, retrieve_oracle_data,
  safe_list_at, validate_oracle_ref_input, value_without_policy_id_as_list,
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
    //TODO this is not cip-113 compatible
    let loanOutputs =
      utils.get_outputs_to_sc(self.outputs, config.loanSpendScriptHash)
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
      get_inputs_from_sc_or_delegated_to_sc(
        self.inputs,
        config.loanSpendScriptHash,
      )
    expect Finite(validFrom) = self.validity_range.lower_bound.bound_type
    expect Finite(validTo) = self.validity_range.upper_bound.bound_type

    and {
      //Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
      length(loanInputs) == length(redeemer.actionsForEachInput),
      list.indexed_foldr(
        loanInputs,
        True,
        fn(index, inputAndCIP113Control, result) {
          //As all inputs must return True, if any of previous input returned False, then fail
          //The last input is not checked but will return its value at the end, so if False withdraw will fail
          expect result

          let input = inputAndCIP113Control.1st
          let isCIP113 = inputAndCIP113Control.2nd
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
              expect Some(bondInput) =
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
                  bondInput,
                ),
                when datum.commonData.liquidationMode is {
                  NoLiquidationFullCollateralClaim -> isRepaymentLate
                  NoLiquidationDutchAuctionClaim -> {
                    expect Some(dutchAuctionOutput) =
                      list.at(
                        get_outputs_to_sc_or_delegated_to_sc(
                          self.outputs,
                          config.ducthAuctionSpendScriptHash,
                          isCIP113,
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
                        input,
                        bondInput,
                        dutchAuctionOutput,
                        validTo,
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
                      equity == collateralValueInPrincipalCurrency - remainingDebt,
                      validate_oracle_ref_input(
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
                          equity: equity,
                          borrowerBondPolicyId: config.borrowerBondPolicyId,
                          borrowerAssetName: datum.borrowerAssetName,
                          principalAssetPolicyId: datum.commonData.principalAsset.policyId,
                          principalAssetName: datum.commonData.principalAsset.assetName,
                          differenceOutput: safe_list_at(self.outputs, index),
                          repaymentSpendScriptHash: config.repaymentSpendScriptHash,
                          repaymentPolicyId: config.loanPolicyId,
                          repaymentId: loanId,
                        ),
                      },
                    }
                  }
                },
              }
            }

            Repay(borrowerBondInputIndex, loanId) -> {
              expect Some(bondInput) =
                list.at(self.inputs, borrowerBondInputIndex)
              expect Some(repaymentOutput) =
                list.at(
                  get_outputs_to_sc_or_delegated_to_sc(
                    self.outputs,
                    config.repaymentSpendScriptHash,
                    isCIP113,
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
                get_repayment_amount(
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
                  bondInput,
                ),
                validate_output_to_repayment(
                  repaymentOutput,
                  datum.commonData.principalAsset,
                  nextRepaymentAmount,
                  config.lenderBondPolicyId,
                  datum.lenderAssetName,
                  "installment_repayment",
                  (loanId, datum.repaidInstallments + 1),
                  config.repaymentSpendScriptHash,
                  config.repaymentPolicyId,
                  loanId,
                ),
                or {
                  and {
                    datum.repaidInstallments == datum.commonData.totalInstallments - 1,
                    quantity_of(self.mint, loanPolicyId, loanId) == -1,
                  },
                  validate_eventual_output_to_loan_for_repayment(
                    safe_list_at(
                      get_outputs_to_sc_or_delegated_to_sc(
                        self.outputs,
                        loanPolicyId,
                        isCIP113,
                      ),
                      index,
                    ),
                    datum,
                    datum.repaidInstallments + 1,
                    input.output.value,
                    input.output.address.stake_credential,
                    isCIP113,
                    config.loanSpendScriptHash,
                    loanPolicyId,
                    loanId,
                  ),
                },
              }
            }
            AddCollateral(borrowerBondInputIndex, addedCollateralAmount, loanId) -> {
              expect Some(bondInput) =
                list.at(self.inputs, borrowerBondInputIndex)
              expect Some(loanOutput) =
                list.at(
                  get_outputs_to_sc_or_delegated_to_sc(
                    self.outputs,
                    loanPolicyId,
                    isCIP113,
                  ),
                  index,
                )
              and {
                addedCollateralAmount > 0,
                quantity_of(input.output.value, loanPolicyId, loanId) == 1,
                is_nft_spent(
                  config.borrowerBondPolicyId,
                  datum.borrowerAssetName,
                  bondInput,
                ),
                validate_output_to_loan_for_adding_collateral(
                  loanOutput,
                  datum,
                  addedCollateralAmount,
                  input.output.value,
                  input.output.address.stake_credential,
                  isCIP113,
                  config.loanSpendScriptHash,
                ),
              }
            }
            Recast(borrowerBondInputIndex, principalPaid, loanId) -> {
              expect Some(bondInput) =
                list.at(self.inputs, borrowerBondInputIndex)
              expect Some(repaymentOutput) =
                list.at(
                  get_outputs_to_sc_or_delegated_to_sc(
                    self.outputs,
                    config.repaymentSpendScriptHash,
                    isCIP113,
                  ),
                  index,
                )
              //TODO is this the correct way to know how much debt you have after the recast?
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
                quantity_of(input.output.value, loanPolicyId, loanId) == 1,
                is_nft_spent(
                  config.borrowerBondPolicyId,
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
                  config.lenderBondPolicyId,
                  datum.lenderAssetName,
                  "recast",
                  loanId,
                  config.repaymentSpendScriptHash,
                  config.repaymentPolicyId,
                  loanId,
                ),
                or {
                  and {
                    debtAfterRecasting == 0,
                    quantity_of(self.mint, loanPolicyId, loanId) == -1,
                  },
                  and {
                    debtAfterRecasting > 0,
                    validate_eventual_output_to_loan_for_recasting(
                      safe_list_at(
                        get_outputs_to_sc_or_delegated_to_sc(
                          self.outputs,
                          loanPolicyId,
                          isCIP113,
                        ),
                        index,
                      ),
                      datum,
                      principalPaid,
                      input.output.value,
                      input.output.address.stake_credential,
                      isCIP113,
                      config.loanSpendScriptHash,
                    ),
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
  equity: Int,
  borrowerBondPolicyId: ByteArray,
  borrowerAssetName: AssetName,
  principalAssetPolicyId: ByteArray,
  principalAssetName: AssetName,
  differenceOutput: Output,
  repaymentSpendScriptHash: ByteArray,
  repaymentPolicyId: ByteArray,
  repaymentId: ByteArray,
) {
  expect InlineDatum(outputDatum) = differenceOutput.datum
  expect parsedDatum: RepaymentDatum = outputDatum

  let borrowerAsset =
    Asset { policyId: borrowerBondPolicyId, assetName: borrowerAssetName }
  let newDatum =
    RepaymentDatumWithToken {
      action: "partial_liquidation",
      data: None,
      ownerAsset: borrowerAsset,
    }

  let containsCorrectAmount =
    quantity_of(
      differenceOutput.value,
      principalAssetPolicyId,
      principalAssetName,
    ) == equity

  let isDatumCorrect = parsedDatum == newDatum
  let containsRepaymentNFT =
    quantity_of(differenceOutput.value, repaymentPolicyId, repaymentId) == 1
  let dosProtection = length(flatten(differenceOutput.value)) <= 21
  and {
    is_output_to_sc(differenceOutput, repaymentSpendScriptHash),
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
  lenderBondPolicyId: ByteArray,
  lenderAssetName: AssetName,
  action: ByteArray,
  extra_data: Data,
  repaymentSpendScriptHash: ByteArray,
  repaymentPolicyId: ByteArray,
  repaymentId: ByteArray,
) {
  expect InlineDatum(outputDatum) = repaymentOutput.datum
  expect parsedDatum: RepaymentDatum = outputDatum

  let lenderAsset =
    Asset { policyId: lenderBondPolicyId, assetName: lenderAssetName }
  let newDatum =
    RepaymentDatumWithToken {
      action,
      data: extra_data,
      ownerAsset: lenderAsset,
    }
  let containsCorrectAmount =
    quantity_of(repaymentOutput.value, loanAsset.policyId, loanAsset.assetName) >= repaymentAmount
  let containsRepaymentNFT =
    quantity_of(repaymentOutput.value, repaymentPolicyId, repaymentId) == 1
  let isDatumCorrect = parsedDatum == newDatum
  let dosProtection = length(flatten(repaymentOutput.value)) <= 3
  and {
    is_output_to_sc(repaymentOutput, repaymentSpendScriptHash),
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
  loanValue: Value,
  prevStakeCredential: Option<StakeCredential>,
  isCIP113: Bool,
  loanSpendScriptHash: ByteArray,
  loanPolicyId: ByteArray,
  loanId: ByteArray,
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
  let containsLoanNFT = quantity_of(loanOutput.value, loanPolicyId, loanId) == 1
  let isDatumCorrect = parsedDatum == newDatum

  let toCorrectStaking = or {
      isCIP113 == True,
      loanOutput.address.stake_credential == prevStakeCredential,
    }
  and {
    is_output_to_sc(loanOutput, loanSpendScriptHash),
    toCorrectStaking,
    isDatumCorrect,
    containsLoanNFT,
    loanOutput.value == loanValue,
  }
}

fn validate_output_to_loan_for_adding_collateral(
  loanOutput: Output,
  datum: LoanDatum,
  additionalCollateralAmount: Int,
  loanValue: Value,
  prevStakeCredential: Option<StakeCredential>,
  isCIP113: Bool,
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

  let toCorrectStaking = or {
      isCIP113 == True,
      loanOutput.address.stake_credential == prevStakeCredential,
    }

  and {
    is_output_to_sc(loanOutput, loanSpendScriptHash),
    toCorrectStaking,
    parsedDatum == datum,
    //loanNFT is already included in the value
    correctValue,
  }
}

fn validate_eventual_output_to_loan_for_recasting(
  loanOutput: Output,
  datum: LoanDatum,
  principalPaid: Int,
  loanValue: Value,
  prevStakeCredential: Option<StakeCredential>,
  isCIP113: Bool,
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

  let toCorrectStaking = or {
      isCIP113 == True,
      loanOutput.address.stake_credential == prevStakeCredential,
    }
  and {
    is_output_to_sc(loanOutput, loanSpendScriptHash),
    toCorrectStaking,
    parsedDatum == newDatum,
    //loanNFT is already included in the value
    loanOutput.value == loanValue,
  }
}

fn validate_output_to_dutch_auction(
  loanInput: Input,
  borrower_bond_input: Input,
  dutchAuctionOutput: Output,
  validTo: Int,
  lenderAuthHash: ByteArray,
  lenderAddress: Address,
  principalAsset: Asset,
  remainingDebt: Int,
  config: ConfigDatum,
) {
  expect InlineDatum(outputDatum) = dutchAuctionOutput.datum
  expect parsedDatum: DutchAuctionDatum = outputDatum
  let borrowerAddress = borrower_bond_input.output.address

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
  and {
    is_output_to_sc(dutchAuctionOutput, config.ducthAuctionSpendScriptHash),
    //TODO No staking check here, right?
    isDatumCorrect,
    loanInput.output.value == dutchAuctionOutput.value,
  }
}
