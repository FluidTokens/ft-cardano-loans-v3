use aiken/builtin
use aiken/collection/dict
use aiken/collection/list.{length}
use cardano/address.{Address, Credential, Script}
use cardano/assets.{PolicyId, tokens}
use cardano/transaction.{InlineDatum, Output, Transaction, Withdraw}
use fluidtokens/types/pool.{Cancel, PoolWithdrawRedeemer} as pw
use fluidtokens/types/pool_manager.{
  CancelPoolManager, CompoundLiquidity, PoolManagerDatum,
  PoolManagerMintRedeemer, PoolManagerWithdrawRedeemer, UpdatePoolManager,
}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{get_inputs_from_smart_credential} as st_utils

validator poolManager(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  poolSpendScriptHash: ByteArray,
  poolWithdrawScriptHash: ByteArray,
  poolManagerCancelPoolManagerScriptHash: ByteArray,
  poolManagerUpdatePoolManagerScriptHash: ByteArray,
  poolManagerCompoundLiquidityScriptHash: ByteArray,
) {
  mint(
    redeemer: PoolManagerMintRedeemer,
    policy_id: PolicyId,
    self: Transaction,
  ) {
    check_mint(
      self,
      redeemer,
      policy_id,
      configNFTPolicyId,
      configNFTAssetName,
      poolSpendScriptHash,
      poolWithdrawScriptHash,
    )
  }

  withdraw(
    redeemer: PoolManagerWithdrawRedeemer,
    _credential: Credential,
    self: Transaction,
  ) {
    let actionWithdrawScriptHash =
      when redeemer.action is {
        CancelPoolManager { .. } -> poolManagerCancelPoolManagerScriptHash
        UpdatePoolManager { .. } -> poolManagerUpdatePoolManagerScriptHash
        CompoundLiquidity { .. } -> poolManagerCompoundLiquidityScriptHash
      }

    list.any(
      self.withdrawals,
      fn(withdrawal) {
        when withdrawal is {
          Pair(Script(scriptHash), _amnt) ->
            scriptHash == actionWithdrawScriptHash
          _ -> False
        }
      },
    )
  }

  else(_) {
    fail
  }
}

fn check_mint(
  self: Transaction,
  redeemer: PoolManagerMintRedeemer,
  policy_id: PolicyId,
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  poolSpendScriptHash: ByteArray,
  poolWithdrawScriptHash: ByteArray,
) {
  let config =
    utils.get_config_as_data_list(
      safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
      configNFTPolicyId,
      configNFTAssetName,
    )
  let smartTokensSpendScriptHash =
    builtin.un_b_data(utils.safe_list_at(config, 0))
  let poolPolicyId = builtin.un_b_data(utils.safe_list_at(config, 2))
  let poolManagerSpendScriptHash =
    builtin.un_b_data(utils.safe_list_at(config, 26))

  let (poolManagerMintedNFTs, poolManagerBurntNFTs) =
    list.partition(
      dict.to_pairs(tokens(self.mint, policy_id)),
      fn(Pair(_assetName, quantity)) { quantity > 0 },
    )

  let poolInputs =
    get_inputs_from_smart_credential(
      self.inputs,
      Script(poolSpendScriptHash),
      Script(poolWithdrawScriptHash),
      smartTokensSpendScriptHash,
    )

  let poolManagerOutputs =
    list.filter(
      self.outputs,
      fn(output) {
        output.address.payment_credential == Script(poolManagerSpendScriptHash)
      },
    )

  let isEachMintedTokenAccountedFor =
    utils.indexed_all(
      poolManagerMintedNFTs,
      fn(index, Pair(assetName, quantity)) {
        let output = utils.safe_list_at(poolManagerOutputs, index)
        let outputHasUniqueToken = and {
            dict.size(assets.tokens(output.value, policy_id)) == 1,
            assets.quantity_of(output.value, policy_id, assetName) == 1,
          }
        let correctAddress =
          output.address.payment_credential == Script(
            poolManagerSpendScriptHash,
          )
        //Correct datum type
        expect InlineDatum(outputDatum) = output.datum
        expect PoolManagerDatum { .. } = outputDatum

        and {
          quantity == 1,
          outputHasUniqueToken,
          correctAddress,
        }
      },
    )

  //Only pool cancel (or edit) must allow burning of the PoolManager NFT
  let poolManagerBurntOnlyInAllowedActions =
    if length(poolManagerBurntNFTs) > 0 {
      let poolWithdrawRedeemer =
        safe_list_at(self.redeemers, redeemer.poolWithdrawRedeemerIndex)
      expect
        poolWithdrawRedeemer.1st == Withdraw(Script(poolWithdrawScriptHash))
      expect poolRedeemer: PoolWithdrawRedeemer = poolWithdrawRedeemer.2nd
      when poolRedeemer.action is {
        pw.Cancel { .. } -> {
          let poolBurntNFTs =
            list.filter(
              dict.to_pairs(tokens(self.mint, poolPolicyId)),
              fn(Pair(_assetName, quantity)) { quantity < 0 },
            )
          //All pool manager NFTs burnt must have same asset name of all pool NFTs burnt
          poolManagerBurntNFTs == poolBurntNFTs
        }
        _ -> False
      }
    } else {
      True
    }

  let poolMintedNFTs =
    list.filter(
      dict.to_pairs(tokens(self.mint, poolPolicyId)),
      fn(Pair(_assetName, quantity)) { quantity > 0 },
    )
  //NOTE: We don't check the destination of the minted NFTs, as it's the pool owner interest to put them in this SC
  //When you mint a pool you also mint this NFT with same AssetName
  //When you cancel (burn) a pool you also burn this NFT
  //When you edit (cancel+recreate) a pool you also burn and remint this NFT
  and {
    length(poolInputs) == length(poolManagerBurntNFTs),
    poolManagerBurntOnlyInAllowedActions,
    poolManagerMintedNFTs == poolMintedNFTs,
    isEachMintedTokenAccountedFor,
  }
}
