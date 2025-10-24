use aiken/builtin
use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/assets.{flatten, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use fluidtokens/constants
use fluidtokens/types/general.{Asset, CollateralAsset}
use fluidtokens/types/lender_smart_manager.{
  LSMLiquidateWithdrawRedeemer, LenderSmartManagerDatum,
} as lsm
use fluidtokens/types/loan.{LoanDatum} as l
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
) {
  withdraw(
    redeemer: LSMLiquidateWithdrawRedeemer,
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
    let lsmInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(lenderSmartManagerSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )
    let lsmOutputs =
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
    let lenderBondInputs = lsmInputs
    let (lenderBondOutputs, lsmAssetsOutputs) =
      list.partition(
        lsmOutputs,
        fn(output) {
          expect InlineDatum(outputDatum) = output.datum
          if outputDatum is LenderSmartManagerDatum {
            True
          } else {
            //We still expect the datum to be RepaymentDatumWithToken here
            False
          }
        },
      )
    let liquidatedCollateralOutputsAreCorrect =
      list.indexed_foldr(
        loanInputs,
        False,
        fn(index, loanInput, result) {
          //As all inputs must return True, if any of previous input returned False, then fail
          //The last input is not checked but will return its value at the end, so if False withdraw will fail
          expect result
          let lenderBondIndex =
            safe_list_at(redeemer.lenderBondInputIndexes, index)
          let lenderBondInput = safe_list_at(lenderBondInputs, lenderBondIndex)
          let lsmAssetsOutput = safe_list_at(lsmAssetsOutputs, index)
          let lenderBondOutput =
            safe_list_at(lenderBondOutputs, lenderBondIndex)

          expect InlineDatum(loanInputDatum) = loanInput.output.datum
          expect LoanDatum { collateral, .. } = loanInputDatum
          expect InlineDatum(inputLenderBondDatum) =
            lenderBondInput.output.datum
          expect LenderSmartManagerDatum {
            shouldLiquidationConvertToPrincipal,
            liquidationFeePerMille,
            ..
          } = inputLenderBondDatum
          let collateralPolicyId = collateral.policyId
          expect Some(collateralAssetName) = collateral.maybeAssetName
          let loanCollateralAmount =
            quantity_of(
              loanInput.output.value,
              collateralPolicyId,
              collateralAssetName,
            )
          let liquidationFee =
            loanCollateralAmount * liquidationFeePerMille / 1000
          let loanCollateralToSend = loanCollateralAmount - liquidationFee

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
            //Lender bond must NOT allow conversion to principal
            shouldLiquidationConvertToPrincipal == False,
            //Output with lender bond must be the same as input
            builtin.equals_data(lenderBondInput.output, lenderBondOutput),
            //TODO Works only for full liquidations
            validate_repayment_output(
              loanInputOutputReference: loanInput.output_reference,
              repaymentOutput: lsmAssetsOutput,
              lenderBondAsset: Asset {
                policyId: lenderBondPolicyId,
                assetName: lenderBondAssetName,
              },
              repaymentAsset: Asset(collateralPolicyId, collateralAssetName),
              repaymentAmount: loanCollateralToSend,
              action: constants.claimed_collateral_action,
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
    if repaymentAsset.policyId == "" {
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
