use aiken/builtin
use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/lender_smart_manager.{
  LSMWithdrawBondsWithdrawRedeemer, LenderSmartManagerDatum,
} as lsm
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{get_inputs_from_smart_credential} as st_utils

validator actionValidator(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  lenderSmartManagerSpendScriptHash: ByteArray,
) {
  withdraw(
    redeemer: LSMWithdrawBondsWithdrawRedeemer,
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
    list.foldr(
      lsmInputs,
      True,
      fn(input, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        expect InlineDatum(inputDatum) = input.output.datum
        expect LenderSmartManagerDatum { lenderAuth, .. } = inputDatum
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
    )
  }

  else(_) {
    fail
  }
}
