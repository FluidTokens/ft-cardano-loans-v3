use aiken/builtin
use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use cardano/address.{Address, Credential, Inline, Script}
use cardano/assets.{AssetName, flatten, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use fluidtokens/constants
use fluidtokens/finance.{
  can_liquidate, get_collateral_amount, get_equity, get_remaining_debt,
  is_repayment_late,
}
use fluidtokens/oracle.{retrieve_oracle_data}
use fluidtokens/types/dutch_auction.{DutchAuctionDatum}
use fluidtokens/types/general.{
  Asset, AuthorizationMethod, CollateralAsset, Liquidation,
  NoLiquidationDutchAuctionClaim, NoLiquidationFullCollateralClaim,
  PerpetualLoan,
}
use fluidtokens/types/loan.{LoanClaimActionWithdrawRedeemer, LoanDatum} as l
use fluidtokens/types/repayment.{RepaymentDatumWithToken}
use fluidtokens/utils.{is_nft_in_output, quantity_of_policy_id, safe_list_at}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
  is_output_to_script_smart_credential,
} as st_utils

validator loan_claim_action(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  withdraw(
    redeemer: LoanClaimActionWithdrawRedeemer,
    _credential: Credential,
    self: Transaction,
  ) {
    let config =
      utils.get_config_as_data_list(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let smartTokensSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 0))
    let loanSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 10))
    let loanPolicyId = builtin.un_b_data(utils.safe_list_at(config, 6))
    let borrowerBondPolicyId = builtin.un_b_data(utils.safe_list_at(config, 4))
    let lenderBondPolicyId = builtin.un_b_data(utils.safe_list_at(config, 5))
    let dutchAuctionSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 16))
    let dutchAuctionWithdrawScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 17))
    let dutchAuctionStartingIncreasePerMille =
      builtin.un_i_data(utils.safe_list_at(config, 18))
    let dutchAuctionLoweringAmount =
      builtin.un_i_data(utils.safe_list_at(config, 19))
    let dutchAuctionLoweringFrequency =
      builtin.un_i_data(utils.safe_list_at(config, 20))
    let dutchAuctionMinPriceToCancel =
      builtin.un_i_data(utils.safe_list_at(config, 21))
    let repaymentPolicyId = builtin.un_b_data(utils.safe_list_at(config, 7))
    let loanInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(loanSpendScriptHash),
        Script(loanPolicyId),
        smartTokensSpendScriptHash,
      )

    //As we loop through the inputs we DO NOT need to ensure that the number of actions is equal to the number of inputs
    list.indexed_foldr(
      loanInputs,
      True,
      fn(index, input, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result
        let inputAction = safe_list_at(redeemer.actionsForEachInput, index)

        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: LoanDatum = inputDatum
        expect Some(interestRateAsRational) =
          rational.new(datum.interestRate, 10000)

        expect (Finite(validFrom), Finite(validTo)) =
          (
            self.validity_range.lower_bound.bound_type,
            self.validity_range.upper_bound.bound_type,
          )
        let (lenderBondInput, borrowerBondRefInput) =
          (
            utils.safe_list_at(self.inputs, inputAction.lenderBondInputIndex),
            utils.safe_list_at(
              self.reference_inputs,
              inputAction.borrowerBondRefInputIndex,
            ),
          )
        let isPerpetualLoan =
          when datum.repaymentMode is {
            PerpetualLoan { .. } -> True
            _ -> False
          }
        let isRepaymentLate =
          is_repayment_late(
            isPerpetualLoan,
            validFrom,
            datum.lendDate,
            datum.initialGracePeriod,
            datum.repaidInstallments,
            datum.installmentPeriod,
            datum.repaymentTimeWindow,
          )
        and {
          inputAction.liquidationMode == datum.liquidationMode,
          quantity_of(input.output.value, loanPolicyId, inputAction.loanId) == 1,
          utils.efficient_quantity_of(
            borrowerBondRefInput,
            borrowerBondPolicyId,
            inputAction.borrowerBondRefInputPolicyIdIndex,
            inputAction.loanId,
            inputAction.borrowerBondRefInputAssetNameIndex,
          ) == 1,
          quantity_of(self.mint, loanPolicyId, inputAction.loanId) == -1,
          is_nft_in_output(
            lenderBondPolicyId,
            inputAction.loanId,
            lenderBondInput.output,
          ),
          when datum.liquidationMode is {
            NoLiquidationFullCollateralClaim -> isRepaymentLate
            NoLiquidationDutchAuctionClaim -> {
              let dutchAuctionOutput =
                utils.safe_list_at(
                  get_outputs_to_smart_credential(
                    self.outputs,
                    Script(dutchAuctionSpendScriptHash),
                    Script(dutchAuctionWithdrawScriptHash),
                    smartTokensSpendScriptHash,
                  ),
                  index,
                )
              let remainingDebt =
                get_remaining_debt(
                  datum.repaymentMode,
                  rational.from_int(datum.principalAmount),
                  interestRateAsRational,
                  datum.totalInstallments,
                  datum.repaidInstallments,
                  datum.installmentPeriod,
                  datum.initialGracePeriod,
                  validFrom - datum.lendDate,
                )
              and {
                isRepaymentLate,
                validate_output_to_dutch_auction(
                  input,
                  dutchAuctionOutput,
                  borrowerBondRefInput.output.address,
                  lenderBondInput.output.address,
                  inputAction.lenderAuth,
                  validTo,
                  datum.principalAsset,
                  datum.collateral,
                  remainingDebt,
                  dutchAuctionStartingIncreasePerMille,
                  dutchAuctionLoweringAmount,
                  dutchAuctionLoweringFrequency,
                  dutchAuctionMinPriceToCancel,
                  dutchAuctionSpendScriptHash,
                  dutchAuctionWithdrawScriptHash,
                  smartTokensSpendScriptHash,
                ),
              }
            }

            Liquidation { lTV, lTVDivider, partialLiquidationPenaltyPerMille } -> {
              let principalAmountAsRational =
                rational.from_int(datum.principalAmount)
              let collateralOracleRefInput =
                safe_list_at(
                  self.reference_inputs,
                  inputAction.collateralOracleRefInputIndex,
                )
              expect Some(collateralOraclePriceFeed) =
                retrieve_oracle_data(
                  collateralOracleRefInput.output.address.payment_credential,
                  collateralOracleRefInput.output.value,
                  self.redeemers,
                  validFrom,
                  validTo,
                  datum.collateral.oracleTokenAsset.policyId,
                  datum.collateral.oracleTokenAsset.assetName,
                  datum.collateral.policyId,
                  datum.collateral.maybeAssetName,
                )
              let principalOracleRefInput =
                safe_list_at(
                  self.reference_inputs,
                  inputAction.principalOracleRefInputIndex,
                )
              expect Some(principalOraclePriceFeed) =
                retrieve_oracle_data(
                  principalOracleRefInput.output.address.payment_credential,
                  principalOracleRefInput.output.value,
                  self.redeemers,
                  validFrom,
                  validTo,
                  datum.principalOracleAsset.policyId,
                  datum.principalOracleAsset.assetName,
                  datum.principalAsset.policyId,
                  Some(datum.principalAsset.assetName),
                )
              let remainingDebtAsRational =
                rational.from_int(
                  get_remaining_debt(
                    datum.repaymentMode,
                    principalAmountAsRational,
                    interestRateAsRational,
                    datum.totalInstallments,
                    datum.repaidInstallments,
                    datum.installmentPeriod,
                    datum.initialGracePeriod,
                    validFrom - datum.lendDate,
                  ),
                )
              let collateralAmount =
                get_collateral_amount(input.output.value, datum.collateral)
              expect Some(ltvAsRational) = rational.new(lTV, lTVDivider)
              let borrowerBondAddress = borrowerBondRefInput.output.address
              and {
                inputAction.equity == get_equity(
                  collateralAmount,
                  remainingDebtAsRational,
                  principalOraclePriceFeed,
                  collateralOraclePriceFeed,
                  partialLiquidationPenaltyPerMille,
                ),
                or {
                  isRepaymentLate,
                  can_liquidate(
                    remainingDebtAsRational,
                    collateralAmount,
                    ltvAsRational,
                    principalOraclePriceFeed,
                    collateralOraclePriceFeed,
                  ),
                },
                or {
                  partialLiquidationPenaltyPerMille < 0,
                  inputAction.equity <= 0,
                  {
                    let borrowerCompensationOutput =
                      utils.safe_list_at(
                        get_outputs_to_smart_credential(
                          self.outputs,
                          borrowerBondAddress.payment_credential,
                          borrowerBondAddress.payment_credential,
                          smartTokensSpendScriptHash,
                        ),
                        index,
                      )
                    equity_sent_to_borrower(
                      loanInputOutputReference: input.output_reference,
                      equityOutput: borrowerCompensationOutput,
                      equity: inputAction.equity,
                      borrowerBondAsset: Asset {
                        policyId: borrowerBondPolicyId,
                        assetName: inputAction.loanId,
                      },
                      principalAssetPolicyId: datum.principalAsset.policyId,
                      principalAssetName: datum.principalAsset.assetName,
                      repaymentReceipts: datum.repaymentReceipts,
                      repaymentPolicyId: repaymentPolicyId,
                    )
                  },
                },
              }
            }
          },
        }
      },
    )
  }

  else(_) {
    fail
  }
}

fn validate_output_to_dutch_auction(
  loanInput: Input,
  dutchAuctionOutput: Output,
  borrowerAddress: Address,
  lenderAddress: Address,
  lenderAuth: AuthorizationMethod,
  validTo: Int,
  principalAsset: Asset,
  collateral: CollateralAsset,
  remainingDebt: Int,
  dutchAuctionStartingIncreasePerMille: Int,
  dutchAuctionLoweringAmount: Int,
  dutchAuctionLoweringFrequency: Int,
  dutchAuctionMinPriceToCancel: Int,
  dutchAuctionSpendScriptHash: ByteArray,
  dutchAuctionWithdrawScriptHash: ByteArray,
  smartTokensSpendScriptHash: ByteArray,
) {
  expect InlineDatum(outputDatum) = dutchAuctionOutput.datum

  let newDatum =
    DutchAuctionDatum {
      ownerAuth: lenderAuth,
      ownerAddress: lenderAddress,
      currency: principalAsset,
      startingPrice: remainingDebt * dutchAuctionStartingIncreasePerMille / 1000,
      loweringAmount: dutchAuctionLoweringAmount,
      loweringFrequency: dutchAuctionLoweringFrequency,
      minPriceToCancel: dutchAuctionMinPriceToCancel,
      startDate: validTo,
      borrowerAddress: Some(borrowerAddress),
      debtAmount: remainingDebt,
    }
  let isDatumCorrect = builtin.equals_data(outputDatum, newDatum)

  //No other type of stake credential should be allowed
  expect Some(Inline(_lenderStakeCredential)) = lenderAddress.stake_credential

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
    length(flatten(dutchAuctionOutput.value)) == length(
      flatten(loanInput.output.value),
    ) - 1

  and {
    is_output_to_script_smart_credential(
      dutchAuctionOutput,
      Script(dutchAuctionSpendScriptHash),
      Script(dutchAuctionWithdrawScriptHash),
      smartTokensSpendScriptHash,
    ),
    isDatumCorrect,
    correctValue,
    dosProtection,
  }
}

fn equity_sent_to_borrower(
  loanInputOutputReference: OutputReference,
  equityOutput: Output,
  equity: Int,
  borrowerBondAsset: Asset,
  principalAssetPolicyId: ByteArray,
  principalAssetName: AssetName,
  repaymentReceipts: Bool,
  repaymentPolicyId: ByteArray,
) {
  expect InlineDatum(outputDatum) = equityOutput.datum
  let newDatum =
    RepaymentDatumWithToken {
      inputOutputReference: loanInputOutputReference,
      action: constants.repayment_action_partial_liquidation,
      data: None,
      ownerAsset: borrowerBondAsset,
    }

  let containsCorrectAmount =
    quantity_of(equityOutput.value, principalAssetPolicyId, principalAssetName) >= equity

  let receiptCondition =
    repaymentReceipts == False || quantity_of(
      equityOutput.value,
      repaymentPolicyId,
      utils.hash_output_ref(loanInputOutputReference),
    ) == 1

  let isDatumCorrect = builtin.equals_data(outputDatum, newDatum)
  let receiptAssetCount =
    if repaymentReceipts {
      1
    } else {
      0
    }
  let dosProtection =
    if principalAssetPolicyId == "" {
      length(flatten(equityOutput.value)) == 1 + receiptAssetCount
    } else {
      length(flatten(equityOutput.value)) == 2 + receiptAssetCount
    }
  and {
    //No staking check here
    isDatumCorrect,
    containsCorrectAmount,
    receiptCondition,
    dosProtection,
  }
}
