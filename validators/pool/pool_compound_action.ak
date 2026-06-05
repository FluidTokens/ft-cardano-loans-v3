use aiken/builtin
use cardano/address.{Credential, Script}
use cardano/assets.{ada_policy_id, add, quantity_of, without_lovelace}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/pool.{PoolCompoundActionWithdrawRedeemer, PoolDatum}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator pool_compound_action(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  withdraw(
    redeemer: PoolCompoundActionWithdrawRedeemer,
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
    let poolOutputs =
      get_outputs_to_smart_credential(
        self.outputs,
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
        let output = safe_list_at(poolOutputs, index)
        let principal = datum.commonData.principalAsset

        let inputPrincipal =
          quantity_of(
            input.output.value,
            principal.policyId,
            principal.assetName,
          )

        let outputPrincipal =
          quantity_of(output.value, principal.policyId, principal.assetName)

        let addedPrincipal = outputPrincipal - inputPrincipal
        and {
          //Pool NFT is kept in the Pool contract
          quantity_of(input.output.value, poolPolicyId, redeemerAction.poolId) == 1,
          //You must only add principal to the pool during compound
          addedPrincipal > 0,
          //Value must be same except for the added principal
          if principal.policyId == ada_policy_id {
            builtin.equals_data(
              output.value,
              input.output.value
                |> add(principal.policyId, principal.assetName, addedPrincipal),
            )
          } else {
            builtin.equals_data(
              without_lovelace(output.value),
              without_lovelace(
                input.output.value
                  |> add(
                      principal.policyId,
                      principal.assetName,
                      addedPrincipal,
                    ),
              ),
            )
          },
          //No change of pool address
          builtin.equals_data(output.address, input.output.address),
          //Datum doesn't change, value can change and it's not checked here
          builtin.equals_data(output.datum, input.output.datum),
          //You must be authorized to compound (for ex. the Pool Manager NFT)
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
