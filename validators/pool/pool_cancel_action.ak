use aiken/builtin
use cardano/address.{Credential, Script}
use cardano/assets.{quantity_of}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/pool.{PoolCancelActionWithdrawRedeemer, PoolDatum}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{get_inputs_from_smart_credential} as st_utils

validator pool_cancel_action(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  withdraw(
    redeemer: PoolCancelActionWithdrawRedeemer,
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
    let poolSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 8))
    let poolPolicyId = builtin.un_b_data(utils.safe_list_at(config, 2))
    let poolInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(poolSpendScriptHash),
        Script(poolPolicyId),
        smartTokensSpendScriptHash,
      )

    //As we loop through the inputs we DO NOT need to ensure that the number of actions is equal to the number of inputs
    utils.indexed_all(
      poolInputs,
      fn(index, input) {
        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: PoolDatum = inputDatum
        let redeemerAction = safe_list_at(redeemer.actionsForEachInput, index)
        and {
          quantity_of(input.output.value, poolPolicyId, redeemerAction.poolId) == 1,
          quantity_of(self.mint, poolPolicyId, redeemerAction.poolId) == -1,
          authorize_action(
            create_auth(
              datum.lenderAuth,
              self.inputs,
              self.withdrawals,
              self.extra_signatories,
              self.mint,
            ),
          ),
        }
      },
    )
  }

  else(_) {
    fail
  }
}
