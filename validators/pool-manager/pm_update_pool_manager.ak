use aiken/builtin
use aiken/collection/list
use cardano/address.{Address, Credential, Script}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/pool_manager.{
  PoolManagerDatum, UpdatePoolManagerActionWithdrawRedeemer,
}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{get_inputs_from_smart_credential} as st_utils

validator poolManager(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  poolSpendScriptHash: ByteArray,
  poolPolicyId: ByteArray,
  smartTokensSpendScriptHash: ByteArray,
) {
  withdraw(
    redeemer: UpdatePoolManagerActionWithdrawRedeemer,
    _credential: Credential,
    self: Transaction,
  ) {
    let config =
      utils.get_config_as_data_list(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let poolManagerSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 26))

    let poolManagerInputs =
      list.filter(
        self.inputs,
        fn(input) {
          input.output.address.payment_credential == Script(
            poolManagerSpendScriptHash,
          )
        },
      )
    let poolInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(poolSpendScriptHash),
        Script(poolPolicyId),
        smartTokensSpendScriptHash,
      )

    let poolManagerOutputs =
      list.filter(
        self.outputs,
        fn(output) {
          output.address.payment_credential == Script(
            poolManagerSpendScriptHash,
          )
        },
      )
    and {
      //No pools involved
      list.length(poolInputs) == 0,
      utils.indexed_all(
        poolManagerInputs,
        fn(index, input) {
          expect InlineDatum(inputDatum) = input.output.datum
          expect PoolManagerDatum { poolOwnerAuth, .. } = inputDatum

          let poolManagerOutput = safe_list_at(poolManagerOutputs, index)

          //Ensure the output has the correct datum type
          expect InlineDatum(outputDatum) = poolManagerOutput.datum
          expect PoolManagerDatum { .. } = outputDatum

          and {
            //Authorize the pool owner to execute this action
            authorize_action(
              create_auth(
                poolOwnerAuth,
                self.inputs,
                self.withdrawals,
                self.extra_signatories,
                self.mint,
              ),
            ),
            //Output must have same value and address as input
            builtin.equals_data(input.output.value, poolManagerOutput.value),
            builtin.equals_data(input.output.address, poolManagerOutput.address),
          }
        },
      ),
    }
  }

  else(_) {
    fail
  }
}
