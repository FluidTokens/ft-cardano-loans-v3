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
use constants
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
  AddCollateral, Borrow, Claim, LoanMintRedeemer, LoanWithdrawRedeemer, Recast,
  Repay,
}
use utils.{
  get_inputs_from_sc_or_delegated_to_sc, get_outputs_to_sc_or_delegated_to_sc,
  is_nft_spent, is_output_to_sc, quantity_of_policy_id, retrieve_oracle_data,
  safe_list_at, validate_oracle_ref_input, value_without_policy_id_as_list,
}

//TODO Remove loan_id_header?
//TODO Should we limit the max number of minted tokens per tx?
validator loan(configAsset: Asset) {
  mint(redeemer: LoanMintRedeemer, policy_id: PolicyId, self: Transaction) {
    let config =
      utils.get_config(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configAsset.policyId,
        configAsset.assetName,
      )
    let inputRefHash = utils.hash_output_ref(redeemer.inputRef)
    let loanOutputs =
      utils.get_outputs_to_sc(self.outputs, config.loanSpendScriptHash)
    let isInputRefSpent =
      option.is_some(find_input(self.inputs, redeemer.inputRef))

    let isEachMintedTokenAccountedFor =
      list.indexed_foldr(
        dict.to_pairs(tokens(self.mint, policy_id)),
        True,
        fn(index, Pair(assetName, quantity), result) {
          expect result

          if quantity > 0 {
            let poolWithdrawRedeemer =
              safe_list_at(self.redeemers, redeemer.poolWithdrawRedeemerIndex)
            //TODO These 2 checks could be executed only once if there's at least 1 mint
            expect
              poolWithdrawRedeemer.1st == Withdraw(Script(config.poolPolicyId))
            expect Borrow { .. } = poolWithdrawRedeemer.2nd

            let correctAssetName = and {
                utils.token_name_has_header(assetName, constants.loan_id_header),
                bytearray.at(assetName, 1) == index,
                bytearray.drop(assetName, 2) == bytearray.drop(inputRefHash, 2),
              }

            expect Some(output) = list.at(loanOutputs, index)
            let outputHasUniqueToken = and {
                dict.size(assets.tokens(output.value, policy_id)) == 1,
                assets.quantity_of(output.value, policy_id, assetName) == 1,
              }
            and {
              quantity == 1,
              correctAssetName,
              outputHasUniqueToken,
            }
          } else {
            //Burning the tokens is always allowed
            True
          }
        },
      )

    and {
      isInputRefSpent,
      isEachMintedTokenAccountedFor,
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
    let scInputs =
      get_inputs_from_sc_or_delegated_to_sc(
        self.inputs,
        config.loanSpendScriptHash,
      )
    //Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
    expect length(scInputs) == length(redeemer.actionsForEachInput)
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
        expect datum: LoanDatum = inputDatum
        let redeemerAction = safe_list_at(redeemer.actionsForEachInput, index)
        let inputUtxoId = utils.hash_output_ref(input.output_reference)

        when redeemerAction is {
          Claim(
            lenderBondInputIndex,
            collateralOracleRefInputIndex,
            lenderAuthHash,
            lenderAddress,
          ) -> {
            expect Some(bondInput) = list.at(self.inputs, lenderBondInputIndex)
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
              is_nft_spent(
                config.lenderTokenPolicyId,
                datum.lenderAssetName,
                bondInput,
              ),
              when datum.commonData.liquidationMode is {
                NoLiquidationFullCollateralClaim -> isRepaymentLate
                NoLiquidationDutchAuctionClaim -> {
                  expect Finite(validTo) =
                    self.validity_range.upper_bound.bound_type
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
                      difference_sent_to_borrower(
                        collateralValueInPrincipalCurrency: collateralValueInPrincipalCurrency,
                        totalDebtInPrincipalCurrency: remainingDebt,
                        borrowerTokenPolicyId: config.borrowerTokenPolicyId,
                        borrowerAssetName: datum.borrowerAssetName,
                        principalAssetPolicyId: datum.commonData.principalAsset.policyId,
                        principalAssetName: datum.commonData.principalAsset.assetName,
                        differenceOutput: safe_list_at(self.outputs, index),
                        repaymentSpendScriptHash: config.repaymentSpendScriptHash,
                        repaymentPolicyId: config.loanPolicyId,
                        repaymentId: inputUtxoId,
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
              is_nft_spent(
                config.borrowerTokenPolicyId,
                datum.borrowerAssetName,
                bondInput,
              ),
              validate_output_to_repayment(
                repaymentOutput,
                datum.commonData.principalAsset,
                nextRepaymentAmount,
                config.lenderTokenPolicyId,
                datum.lenderAssetName,
                "installment_repayment",
                datum.repaidInstallments + 1,
                config.repaymentSpendScriptHash,
                config.repaymentPolicyId,
                inputUtxoId,
              ),
              or {
                datum.repaidInstallments == datum.commonData.totalInstallments - 1,
                and {
                  quantity_of(input.output.value, loanPolicyId, loanId) == 1,
                  validate_output_to_loan_for_repayment(
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
              is_nft_spent(
                config.borrowerTokenPolicyId,
                datum.borrowerAssetName,
                bondInput,
              ),
              quantity_of(input.output.value, loanPolicyId, loanId) == 1,
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
          Recast(borrowerBondInputIndex, principalPaid) -> {
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
                config.borrowerTokenPolicyId,
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
                config.lenderTokenPolicyId,
                datum.lenderAssetName,
                "recast",
                None,
                config.repaymentSpendScriptHash,
                config.repaymentPolicyId,
                inputUtxoId,
              ),
              or {
                debtAfterRecasting == 0,
                and {
                  debtAfterRecasting > 0,
                  {
                    expect Some(loanOutput) =
                      list.at(
                        get_outputs_to_sc_or_delegated_to_sc(
                          self.outputs,
                          loanPolicyId,
                          isCIP113,
                        ),
                        index,
                      )
                    validate_output_to_loan_for_recasting(
                      loanOutput,
                      datum,
                      principalPaid,
                      input.output.value,
                      input.output.address.stake_credential,
                      isCIP113,
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

fn difference_sent_to_borrower(
  collateralValueInPrincipalCurrency: Int,
  totalDebtInPrincipalCurrency: Int,
  borrowerTokenPolicyId: ByteArray,
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
    Asset { policyId: borrowerTokenPolicyId, assetName: borrowerAssetName }
  let newDatum =
    RepaymentDatumWithToken {
      action: "partial_liquidation",
      data: None,
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
  let containsRepaymentNFT =
    quantity_of(differenceOutput.value, repaymentPolicyId, repaymentId) == 1
  let dosProtection = length(flatten(differenceOutput.value)) <= 21
  or {
    remainingAmount < 0,
    and {
      is_output_to_sc(differenceOutput, repaymentSpendScriptHash),
      //TODO No staking check here, right?
      isDatumCorrect,
      containsRepaymentNFT,
      containsCorrectAmount,
      dosProtection,
    },
  }
}

fn validate_output_to_repayment(
  repaymentOutput: Output,
  loanAsset: Asset,
  repaymentAmount: Int,
  lenderTokenPolicyId: ByteArray,
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
    Asset { policyId: lenderTokenPolicyId, assetName: lenderAssetName }
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

fn validate_output_to_loan_for_repayment(
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

fn validate_output_to_loan_for_recasting(
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
