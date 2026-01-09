use aiken/builtin
use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/assets.{quantity_of}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/general.{Asset}
use fluidtokens/types/lender_manager.{
  LMWithdrawAssetsWithdrawRedeemer, LenderManagerDatum,
} as lm
use fluidtokens/types/repayment.{RepaymentDatumWithToken} as r
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{get_inputs_from_smart_credential} as st_utils

validator actionValidator(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  lenderSmartManagerSpendScriptHash: ByteArray,
) {
  withdraw(
    redeemer: LMWithdrawAssetsWithdrawRedeemer,
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
    let lmInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(lenderSmartManagerSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )
    let (lenderBondInputs, lmAssetsInputs) =
      list.partition(
        lmInputs,
        fn(input) {
          expect InlineDatum(inputDatum) = input.output.datum
          if inputDatum is LenderManagerDatum {
            True
          } else {
            //We still expect the datum to be RepaymentDatumWithToken here
            False
          }
        },
      )

    and {
      utils.indexed_all(
        lmAssetsInputs,
        fn(index, input) {
          expect InlineDatum(inputDatum) = input.output.datum
          expect RepaymentDatumWithToken { ownerAsset, .. } = inputDatum

          let lenderBondIndex =
            safe_list_at(redeemer.lenderBondInputIndexes, index)

          let lenderBondInput = safe_list_at(lenderBondInputs, lenderBondIndex)

          quantity_of(
            lenderBondInput.output.value,
            ownerAsset.policyId,
            ownerAsset.assetName,
          ) == 1
        },
      ),
      list.all(
        lenderBondInputs,
        fn(lenderBondInput: Input) -> Bool {
          expect InlineDatum(inputLenderBondDatum) =
            lenderBondInput.output.datum
          expect LenderManagerDatum { lenderAuth, .. } = inputLenderBondDatum

          authorize_action(
            create_auth(
              lenderAuth,
              self.inputs,
              self.withdrawals,
              self.extra_signatories,
              self.mint,
            ),
          )
        },
      ),
    }
  }

  else(_) {
    fail
  }
}
