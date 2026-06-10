use aiken/builtin
use aiken/collection/list
use cardano/address.{Address, Credential, Script}
use cardano/assets.{quantity_of}
use cardano/transaction.{InlineDatum, Input, Output, Transaction, Withdraw}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/pool.{Cancel, PoolWithdrawRedeemer} as pw
use fluidtokens/types/pool_manager.{
  CancelPoolManagerActionWithdrawRedeemer, PoolManagerDatum,
}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{get_inputs_from_smart_credential} as st_utils

validator poolManager(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  poolSpendScriptHash: ByteArray,
  poolWithdrawScriptHash: ByteArray,
  poolPolicyId: ByteArray,
  smartTokensSpendScriptHash: ByteArray,
) {
  withdraw(
    redeemer: CancelPoolManagerActionWithdrawRedeemer,
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
    let poolManagerPolicyId = builtin.un_b_data(utils.safe_list_at(config, 27))

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

    let zeroPoolInputs = list.length(poolInputs) == 0
    let sameNumberOfPoolsandPoolManagers =
      list.length(poolInputs) == list.length(poolManagerInputs)
    and {
      //Cancel action must be executed
      {
        let poolWithdrawRedeemer =
          safe_list_at(self.redeemers, redeemer.poolWithdrawRedeemerIndex)
        expect
          poolWithdrawRedeemer.1st == Withdraw(Script(poolWithdrawScriptHash))
        expect poolRedeemer: PoolWithdrawRedeemer = poolWithdrawRedeemer.2nd

        when poolRedeemer.action is {
          pw.Cancel { .. } -> True
          _ -> False
        }
      },
      utils.indexed_all(
        poolManagerInputs,
        fn(index, input) {
          expect InlineDatum(inputDatum) = input.output.datum
          expect PoolManagerDatum { poolOwnerAuth, .. } = inputDatum

          let poolManagerNFTAssetName =
            safe_list_at(redeemer.poolManagerNFTAssetNames, index)

          let poolInput = safe_list_at(poolInputs, index)

          and {
            or {
              zeroPoolInputs,
              and {
                //No extra pools spent, otherwise they can be stolen
                sameNumberOfPoolsandPoolManagers,
                //Pool must have same NFT of pool manager
                quantity_of(
                  poolInput.output.value,
                  poolPolicyId,
                  poolManagerNFTAssetName,
                ) == 1,
              },
            },
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
            quantity_of(
              input.output.value,
              poolManagerPolicyId,
              poolManagerNFTAssetName,
            ) == 1,
            quantity_of(self.mint, poolManagerPolicyId, poolManagerNFTAssetName) == -1,
          }
        },
      ),
    }
  }

  else(_) {
    fail
  }
}
