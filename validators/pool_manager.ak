use aiken/builtin
use aiken/collection/dict
use aiken/collection/list.{length}
use cardano/address.{Address, Credential, Script}
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Input, Output, Transaction, Withdraw}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/lender_manager.{LenderManagerWithdrawRedeemer} as lm
use fluidtokens/types/pool_manager.{
  CancelPoolManager, CompoundLiquidity, PoolManagerDatum,
  PoolManagerMintRedeemer, PoolManagerWithdrawRedeemer, UpdatePoolManager,
}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{get_inputs_from_smart_credential} as st_utils

validator poolManager(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  poolManagerSpendScriptHash: ByteArray,
  lenderManagerWithdrawScriptHash: ByteArray,
  poolSpendScriptHash: ByteArray,
  poolWithdrawScriptHash: ByteArray,
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
      poolManagerSpendScriptHash,
      poolSpendScriptHash,
      poolWithdrawScriptHash,
    )
  }

  withdraw(
    redeemer: PoolManagerWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(poolManagerPolicyId) = credential

    let poolManagerInputs =
      list.filter(
        self.inputs,
        fn(input) {
          input.output.address.payment_credential == Script(
            poolManagerSpendScriptHash,
          )
        },
      )
    when redeemer.action is {
      CancelPoolManager { poolManagerNFTAssetNames } ->
        utils.indexed_all(
          poolManagerInputs,
          fn(index, input) {
            expect InlineDatum(inputDatum) = input.output.datum
            expect PoolManagerDatum { poolOwnerAuth, .. } = inputDatum

            let poolManagerNFTAssetName =
              safe_list_at(poolManagerNFTAssetNames, index)

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
              quantity_of(
                input.output.value,
                poolManagerPolicyId,
                poolManagerNFTAssetName,
              ) == 1,
              quantity_of(
                self.mint,
                poolManagerPolicyId,
                poolManagerNFTAssetName,
              ) == -1,
            }
          },
        )
      UpdatePoolManager -> {
        let poolManagerOutputs =
          list.filter(
            self.outputs,
            fn(output) {
              output.address.payment_credential == Script(
                poolManagerSpendScriptHash,
              )
            },
          )
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
              builtin.equals_data(
                input.output.address,
                poolManagerOutput.address,
              ),
            }
          },
        )
      }
      CompoundLiquidity { lenderManagerWithdrawRedeemerIndex } -> {
        //CompoundLiquidity action must be executed
        let lenderManagerWithdrawRedeemer =
          safe_list_at(self.redeemers, lenderManagerWithdrawRedeemerIndex)
        expect
          lenderManagerWithdrawRedeemer.1st == Withdraw(
            Script(lenderManagerWithdrawScriptHash),
          )
        expect lenderManagerRedeemer: LenderManagerWithdrawRedeemer =
          lenderManagerWithdrawRedeemer.2nd

        when lenderManagerRedeemer.action is {
          lm.Compound { .. } -> True
          lm.LiquidatePayInAdvanceAndCompound { .. } -> True
          lm.LiquidateConvertAndCompound { .. } -> True
          _ -> False
        }
      }
    }
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
  poolManagerSpendScriptHash: ByteArray,
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

  //Excluding mint < 0 (ie. burn) means burning is always allowed
  let poolManagerMintedNFTs =
    list.filter(
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

  let poolMintedNFTs =
    list.filter(
      dict.to_pairs(tokens(self.mint, poolPolicyId)),
      fn(Pair(_assetName, quantity)) { quantity > 0 },
    )
  //NOTE: We don't check the destination of the minted NFTs, as it's the pool owner interest to put them in this SC
  //When you mint a pool you also mint this NFT with same AssetName
  //When you cancel (burn) a pool you also burn this NFT
  //When you modify/compound a pool you also burn and remint this NFT
  and {
    length(poolInputs) == 0,
    poolManagerMintedNFTs == poolMintedNFTs,
    isEachMintedTokenAccountedFor,
  }
}
