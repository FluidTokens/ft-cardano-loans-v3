use aiken/builtin
use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/assets.{quantity_of}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/general.{Asset}
use fluidtokens/types/lender_smart_manager.{
  LSMWithdrawAssetsWithdrawRedeemer, LenderSmartManagerDatum,
} as lsm
use fluidtokens/types/repayment.{RepaymentDatumWithToken} as r
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{get_inputs_from_smart_credential} as st_utils

validator actionValidator(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  lenderSmartManagerSpendScriptHash: ByteArray,
) {
  withdraw(
    redeemer: LSMWithdrawAssetsWithdrawRedeemer,
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
    let lsmInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(lenderSmartManagerSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )
    let (lenderBondInputs, lsmAssetsInputs) =
      list.partition(
        lsmInputs,
        fn(input) {
          expect InlineDatum(inputDatum) = input.output.datum
          if inputDatum is LenderSmartManagerDatum {
            True
          } else {
            //We still expect the datum to be RepaymentDatumWithToken here
            False
          }
        },
      )

    and {
      list.indexed_foldr(
        lsmAssetsInputs,
        True,
        fn(index, input, result) {
          //As all inputs must return True, if any of previous input returned False, then fail
          //The last input is not checked but will return its value at the end, so if False withdraw will fail
          expect result

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
      list.foldr(
        lenderBondInputs,
        True,
        fn(lenderBondInput, result) {
          //As all inputs must return True, if any of previous input returned False, then fail
          //The last input is not checked but will return its value at the end, so if False withdraw will fail
          expect result

          expect InlineDatum(inputLenderBondDatum) =
            lenderBondInput.output.datum
          expect LenderSmartManagerDatum { lenderAuth, .. } =
            inputLenderBondDatum

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
