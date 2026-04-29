use aiken/builtin
use cardano/address.{Credential, Script}
use cardano/assets.{quantity_of}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use fluidtokens/types/asset_manager.{
  AssetManagerDatumWithToken, AssetManagerWithdrawRedeemer,
}
use fluidtokens/types/general.{Asset}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{get_inputs_from_smart_credential} as st_utils

validator actionValidator(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  assetManagerSpendScriptHash: ByteArray,
  assetManagerWithdrawScriptHash: ByteArray,
) {
  withdraw(
    redeemer: AssetManagerWithdrawRedeemer,
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
    let amInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(assetManagerSpendScriptHash),
        Script(assetManagerWithdrawScriptHash),
        smartTokensSpendScriptHash,
      )
    utils.indexed_all(
      amInputs,
      fn(index, input) {
        expect InlineDatum(inputDatum) = input.output.datum
        expect AssetManagerDatumWithToken { ownerAsset, .. } = inputDatum

        let lenderBondIndex =
          safe_list_at(redeemer.lenderBondInputIndexes, index)

        let lenderBondInput = safe_list_at(self.inputs, lenderBondIndex)

        quantity_of(
          lenderBondInput.output.value,
          ownerAsset.policyId,
          ownerAsset.assetName,
        ) == 1
      },
    )
  }

  else(_) {
    fail
  }
}
