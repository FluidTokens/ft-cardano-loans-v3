use aiken/builtin
use aiken/collection/list
use aiken/collection/pairs
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use cardano/address.{Address, Credential, PaymentCredential, Script}
use cardano/assets.{ada_policy_id, flatten, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, Withdraw,
}
use fluidtokens/constants
use fluidtokens/finance
use fluidtokens/oracle.{retrieve_oracle_data}
use fluidtokens/types/general.{Asset, CollateralAsset, Liquidation}
use fluidtokens/types/lender_manager.{
  LMLiquidateAndPayInAdvanceWithdrawRedeemer, LenderManagerDatum,
} as lm
use fluidtokens/types/loan.{LoanDatum} as loan
use fluidtokens/types/repayment.{RepaymentDatumWithToken} as r
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator actionValidator(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  lenderSmartManagerSpendScriptHash: ByteArray,
  loanWithdrawScriptHash: ByteArray,
  loanClaimPaymentCredential: PaymentCredential,
) {
  withdraw(
    redeemer: LMLiquidateAndPayInAdvanceWithdrawRedeemer,
    credential: Credential,
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
    let lenderBondPolicyId = builtin.un_b_data(utils.safe_list_at(config, 5))
    expect (Finite(validFrom), Finite(validTo)) =
      (
        self.validity_range.lower_bound.bound_type,
        self.validity_range.upper_bound.bound_type,
      )
    let lmInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(lenderSmartManagerSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )
    let lmOutputs =
      get_outputs_to_smart_credential(
        self.outputs,
        Script(lenderSmartManagerSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )
    let loanInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(loanSpendScriptHash),
        Script(loanWithdrawScriptHash),
        smartTokensSpendScriptHash,
      )
    let lenderBondInputs = lmInputs
    let (lenderBondOutputs, lmAssetsOutputs) =
      list.partition(
        lmOutputs,
        fn(output) {
          expect InlineDatum(outputDatum) = output.datum
          if outputDatum is LenderManagerDatum {
            True
          } else {
            //We still expect the datum to be RepaymentDatumWithToken here
            False
          }
        },
      )
    let liquidatedCollateralOutputsAreCorrect =
      utils.indexed_all(
        loanInputs,
        fn(index, loanInput) {
          let (collateralOracleRefInputIndex, principalOracleRefInputIndex) =
            safe_list_at(
              redeemer.principalAndCollateralOracleRefInputIndexes,
              index,
            )
          let lenderBondIndex =
            safe_list_at(redeemer.lenderBondInputIndexes, index)
          let lenderBondInput = safe_list_at(lenderBondInputs, lenderBondIndex)
          let lmAssetsOutput = safe_list_at(lmAssetsOutputs, index)
          let lenderBondOutput =
            safe_list_at(lenderBondOutputs, lenderBondIndex)
          let collateralOracleRefInput =
            safe_list_at(self.reference_inputs, collateralOracleRefInputIndex)
          let principalOracleRefInput =
            safe_list_at(self.reference_inputs, principalOracleRefInputIndex)

          expect InlineDatum(loanInputDatum) = loanInput.output.datum
          expect LoanDatum {
            collateral,
            principalOracleAsset,
            principalAsset,
            ..
          } = loanInputDatum
          expect Some(loanRedeemer) =
            pairs.get_first(
              self.redeemers,
              Withdraw(loanClaimPaymentCredential),
            )
          expect parsedLoanRedeemer: loan.LoanClaimActionWithdrawRedeemer =
            loanRedeemer
          let loanInputAction =
            safe_list_at(parsedLoanRedeemer.actionsForEachInput, index)
          expect InlineDatum(inputLenderBondDatum) =
            lenderBondInput.output.datum
          expect LenderManagerDatum {
            shouldLiquidationConvertToPrincipal,
            liquidationFeePerMille,
            ..
          } = inputLenderBondDatum
          // Ensure liquidationFeePerMille is non-negative
          expect liquidationFeePerMille >= 0
          let collateralPolicyId = collateral.policyId
          expect Some(collateralAssetName) = collateral.maybeAssetName
          let collateralOracleToken = collateral.oracleTokenAsset
          expect Some(collateralOraclePriceFeed) =
            retrieve_oracle_data(
              collateralOracleRefInput.output.address.payment_credential,
              collateralOracleRefInput.output.value,
              self.redeemers,
              validFrom,
              validTo,
              collateralOracleToken.policyId,
              collateralOracleToken.assetName,
              collateralPolicyId,
              collateral.maybeAssetName,
            )
          expect Some(principalOraclePriceFeed) =
            retrieve_oracle_data(
              principalOracleRefInput.output.address.payment_credential,
              principalOracleRefInput.output.value,
              self.redeemers,
              validFrom,
              validTo,
              principalOracleAsset.policyId,
              principalOracleAsset.assetName,
              principalAsset.policyId,
              Some(principalAsset.assetName),
            )
          let loanCollateralAmount =
            quantity_of(
              loanInput.output.value,
              collateralPolicyId,
              collateralAssetName,
            )
          let liquidationFee =
            loanCollateralAmount * liquidationFeePerMille / 1000
          expect Liquidation { equityInPrincipalCurrency, .. } =
            loanInputAction.liquidationMode
          expect equityInPrincipalCurrency == False
          let loanCollateralThatLenderShouldReceive =
            loanCollateralAmount - loanInputAction.equity - liquidationFee
          let convertedLoanCollateralToPrincipalAmount =
            finance.convertFromAToBWithOracles(
              collateralOraclePriceFeed,
              principalOraclePriceFeed,
              rational.from_int(loanCollateralThatLenderShouldReceive),
            )

          let lenderBondAssetName =
            safe_list_at(redeemer.lenderBondAssetNames, index)

          and {
            //Loan NFT AssetName must be same of lender bond
            quantity_of(
              loanInput.output.value,
              loanPolicyId,
              lenderBondAssetName,
            ) == 1,
            //Lender bond must be present in input
            quantity_of(
              lenderBondInput.output.value,
              lenderBondPolicyId,
              lenderBondAssetName,
            ) == 1,
            //Lender bond must allow conversion to principal
            shouldLiquidationConvertToPrincipal,
            //Output with lender bond must be the same as input
            builtin.equals_data(lenderBondInput.output, lenderBondOutput),
            //Ensures lender receives the correct assets, the eventual output to borrower is already checked by loan.ak
            validate_repayment_output(
              loanInputOutputReference: loanInput.output_reference,
              repaymentOutput: lmAssetsOutput,
              lenderBondAsset: Asset {
                policyId: lenderBondPolicyId,
                assetName: lenderBondAssetName,
              },
              repaymentAsset: Asset(
                principalAsset.policyId,
                principalAsset.assetName,
              ),
              repaymentAmount: convertedLoanCollateralToPrincipalAmount,
              action: constants.converted_to_liquidity_action,
            ),
          }
        },
      )

    and {
      //No additional lender bonds should be spent
      list.length(loanInputs) == list.length(lenderBondInputs),
      liquidatedCollateralOutputsAreCorrect,
    }
  }

  else(_) {
    fail
  }
}

fn validate_repayment_output(
  loanInputOutputReference: OutputReference,
  repaymentOutput: Output,
  lenderBondAsset: Asset,
  repaymentAsset: Asset,
  repaymentAmount: Int,
  action: ByteArray,
) {
  expect InlineDatum(outputDatum) = repaymentOutput.datum
  let newDatum =
    RepaymentDatumWithToken {
      inputOutputReference: loanInputOutputReference,
      action,
      data: None,
      ownerAsset: lenderBondAsset,
    }
  let containsCorrectAmount =
    quantity_of(
      repaymentOutput.value,
      repaymentAsset.policyId,
      repaymentAsset.assetName,
    ) >= repaymentAmount

  let isDatumCorrect = builtin.equals_data(outputDatum, newDatum)

  let dosProtection =
    if repaymentAsset.policyId == ada_policy_id {
      list.length(flatten(repaymentOutput.value)) == 1
    } else {
      list.length(flatten(repaymentOutput.value)) == 2
    }
  and {
    //No staking check here
    isDatumCorrect,
    containsCorrectAmount,
    dosProtection,
  }
}
