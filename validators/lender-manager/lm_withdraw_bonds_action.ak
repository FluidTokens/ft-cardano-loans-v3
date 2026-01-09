use aiken/builtin
use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/lender_manager.{
  LMWithdrawBondsWithdrawRedeemer, LenderManagerDatum,
} as lm
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{get_inputs_from_smart_credential} as st_utils

validator actionValidator(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  lenderSmartManagerSpendScriptHash: ByteArray,
) {
  withdraw(
    redeemer: LMWithdrawBondsWithdrawRedeemer,
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
    list.all(
      lmInputs,
      // the list being traversed (lmInputs or lenderBondInputs)
      fn(input: Input) -> Bool {
        expect InlineDatum(inputDatum) = input.output.datum
        expect LenderManagerDatum { lenderAuth, .. } = inputDatum
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
