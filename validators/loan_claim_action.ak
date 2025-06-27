use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use cardano/address.{Address, Credential, Inline, Script}
use cardano/assets.{AssetName, PolicyId, flatten, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use fluidtokens/constants
use fluidtokens/finance.{
  can_liquidate, get_collateral_amount, get_equity, get_remaining_debt,
  is_repayment_late,
}
use fluidtokens/oracle.{retrieve_oracle_data}
use fluidtokens/types/config.{ConfigDatum}
use fluidtokens/types/dutch_auction.{DutchAuctionDatum}
use fluidtokens/types/general.{Asset, AuthorizationMethod, CollateralAsset}
use fluidtokens/types/loan.{LoanClaimActionWithdrawRedeemer, LoanDatum} as l
use fluidtokens/types/pool.{
  CommonData, Liquidation, LiquidationMode, NoLiquidationDutchAuctionClaim,
  NoLiquidationFullCollateralClaim, PerpetualLoan,
}
use fluidtokens/types/repayment.{RepaymentDatum, RepaymentDatumWithToken}
use fluidtokens/utils.{is_nft_in_output, quantity_of_policy_id, safe_list_at}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
  is_output_to_smart_credential,
} as st_utils

validator loan_claim_action(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  withdraw(
    redeemer: LoanClaimActionWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
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
        let inputAction = safe_list_at(redeemer.action, index)

        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: LoanDatum = inputDatum
        expect Some(interestRateAsRational) =
          rational.new(datum.commonData.interestRate, 10000)

        check_claim(
          self,
          input,
          inputAction.lenderBondInputIndex,
          inputAction.borrowerBondRefInputIndex,
          index,
          config,
          datum,
          inputAction.liquidationMode,
          inputAction.principalOracleRefInputIndex,
          inputAction.collateralOracleRefInputIndex,
          config.loanPolicyId,
          inputAction.loanId,
          inputAction.lenderAuth,
          interestRateAsRational,
          inputAction.equity,
        )
      },
    )
  }

  else(_) {
    fail
  }
}

fn check_claim(
  self: Transaction,
  input: Input,
  lenderBondOutputIndex: Int,
  borrowerBondRefInputIndex: Int,
  loanInputIndex: Int,
  config: ConfigDatum,
  datum: LoanDatum,
  liquidationMode: LiquidationMode,
  principalOracleRefInputIndex: Int,
  collateralOracleRefInputIndex: Int,
  loanPolicyId: PolicyId,
  loanId: ByteArray,
  lenderAuth: AuthorizationMethod,
  interestRateAsRational: rational.Rational,
  equity: Int,
) {
  expect (Finite(validFrom), Finite(validTo)) =
    (
      self.validity_range.lower_bound.bound_type,
      self.validity_range.upper_bound.bound_type,
    )
  expect (Some(lenderBondOutput), Some(borrowerBondRefInput)) =
    (
      list.at(self.outputs, lenderBondOutputIndex),
      list.at(self.reference_inputs, borrowerBondRefInputIndex),
    )
  let isPerpetualLoan =
    when datum.commonData.repaymentMode is {
      PerpetualLoan { .. } -> True
      _ -> False
    }
  let isRepaymentLate =
    is_repayment_late(
      isPerpetualLoan,
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
    is_nft_in_output(config.lenderBondPolicyId, loanId, lenderBondOutput),
    when datum.commonData.liquidationMode is {
      NoLiquidationFullCollateralClaim -> isRepaymentLate
      NoLiquidationDutchAuctionClaim -> {
        expect Some(dutchAuctionOutput) =
          list.at(
            get_outputs_to_smart_credential(
              self.outputs,
              Script(config.dutchAuctionSpendScriptHash),
              Script(config.dutchAuctionWithdrawScriptHash),
              config.smartTokensSpendScriptHash,
            ),
            loanInputIndex,
          )
        let remainingDebt =
          get_remaining_debt(
            datum.commonData.repaymentMode,
            rational.from_int(datum.principalAmount),
            interestRateAsRational,
            datum.totalInstallments,
            datum.repaidInstallments,
            datum.commonData.installmentPeriod,
            datum.commonData.initialGracePeriod,
            validFrom - datum.lendDate,
          )
        and {
          isRepaymentLate,
          validate_output_to_dutch_auction(
            input,
            dutchAuctionOutput,
            borrowerBondRefInput.output.address,
            lenderBondOutput.address,
            lenderAuth,
            config,
            validTo,
            datum.commonData.principalAsset,
            datum.collateral,
            remainingDebt,
          ),
        }
      }
      Liquidation { lTV, lTVDivider, partialLiquidationPenaltyPerMille } -> {
        let principalAmountAsRational = rational.from_int(datum.principalAmount)
        let collateralOracleRefInput =
          safe_list_at(self.reference_inputs, collateralOracleRefInputIndex)
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
          safe_list_at(self.reference_inputs, principalOracleRefInputIndex)
        expect Some(principalOraclePriceFeed) =
          retrieve_oracle_data(
            principalOracleRefInput.output.address.payment_credential,
            principalOracleRefInput.output.value,
            self.redeemers,
            validFrom,
            validTo,
            datum.commonData.principalOracleAsset.policyId,
            datum.commonData.principalOracleAsset.assetName,
            datum.commonData.principalAsset.policyId,
            Some(datum.commonData.principalAsset.assetName),
          )
        let remainingDebt =
          get_remaining_debt(
            datum.commonData.repaymentMode,
            principalAmountAsRational,
            interestRateAsRational,
            datum.totalInstallments,
            datum.repaidInstallments,
            datum.commonData.installmentPeriod,
            datum.commonData.initialGracePeriod,
            validFrom - datum.lendDate,
          )
        let collateralAmount =
          get_collateral_amount(input.output.value, datum.collateral)
        expect Some(ltvAsRational) = rational.new(lTV, lTVDivider)
        let borrowerBondAddress = borrowerBondRefInput.output.address
        expect Some(Inline(borrowerBondStakeCredential)) =
          borrowerBondAddress.stake_credential
        and {
          equity == get_equity(
            collateralAmount,
            rational.from_int(remainingDebt),
            principalOraclePriceFeed,
            collateralOraclePriceFeed,
            partialLiquidationPenaltyPerMille,
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
            partialLiquidationPenaltyPerMille <= 0,
            equity <= 0,
            {
              expect Some(borrowerCompensationOutput) =
                list.at(
                  get_outputs_to_smart_credential(
                    self.outputs,
                    borrowerBondAddress.payment_credential,
                    borrowerBondStakeCredential,
                    config.smartTokensSpendScriptHash,
                  ),
                  loanInputIndex,
                )
              equity_sent_to_borrower(
                loanInputOutputReference: input.output_reference,
                equityOutput: borrowerCompensationOutput,
                equity: equity,
                borrowerBondAsset: Asset {
                  policyId: config.borrowerBondPolicyId,
                  assetName: loanId,
                },
                principalAssetPolicyId: datum.commonData.principalAsset.policyId,
                principalAssetName: datum.commonData.principalAsset.assetName,
                repaymentReceipts: datum.commonData.repaymentReceipts,
                repaymentPolicyId: config.repaymentPolicyId,
              )
            },
          },
        }
      }
    },
  }
}

fn validate_output_to_dutch_auction(
  loanInput: Input,
  dutchAuctionOutput: Output,
  borrowerAddress: Address,
  lenderAddress: Address,
  lenderAuth: AuthorizationMethod,
  config: ConfigDatum,
  validTo: Int,
  principalAsset: Asset,
  collateral: CollateralAsset,
  remainingDebt: Int,
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
    is_output_to_smart_credential(
      dutchAuctionOutput,
      Script(config.dutchAuctionSpendScriptHash),
      Some(Inline(Script(config.dutchAuctionWithdrawScriptHash))),
      config.smartTokensSpendScriptHash,
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
  expect parsedDatum: RepaymentDatum = outputDatum
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

  let isDatumCorrect = parsedDatum == newDatum
  let receiptAssetCount =
    if receiptCondition {
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
