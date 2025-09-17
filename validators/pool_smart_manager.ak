use aiken/builtin
use aiken/collection/dict
use aiken/collection/list.{length}
use cardano/address.{Address, Credential, Script}
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Input, Output, Transaction, Withdraw}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/lender_smart_wallet.{LenderSmartWalletWithdrawRedeemer} as lsw
use fluidtokens/types/pool_smart_manager.{
  CancelPoolManager, CompoundLiquidity, PoolSmartManagerDatum,
  PoolSmartManagerMintRedeemer, PoolSmartManagerWithdrawRedeemer,
  UpdatePoolManager,
}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{get_inputs_from_smart_credential} as st_utils

validator poolSmartManager(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  poolSmartManagerSpendScriptHash: ByteArray,
  lenderSmartWalletWithdrawScriptHash: ByteArray,
  poolSpendScriptHash: ByteArray,
  poolWithdrawScriptHash: ByteArray,
  poolManagerSpendScriptHash: ByteArray,
) {
  mint(
    redeemer: PoolSmartManagerMintRedeemer,
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
    )
  }

  withdraw(
    redeemer: PoolSmartManagerWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(poolSmartManagerPolicyId) = credential

    let poolSmartManagerInputs =
      list.filter(
        self.inputs,
        fn(input) {
          input.output.address.payment_credential == Script(
            poolSmartManagerSpendScriptHash,
          )
        },
      )
    when redeemer.action is {
      CancelPoolManager { poolSmartManagerNFTAssetNames } ->
        list.indexed_foldr(
          poolSmartManagerInputs,
          True,
          fn(index, input, result) {
            //As all inputs must return True, if any of previous input returned False, then fail
            //The last input is not checked but will return its value at the end, so if False withdraw will fail
            expect result

            expect InlineDatum(inputDatum) = input.output.datum
            expect PoolSmartManagerDatum { poolOwnerAuth, .. } = inputDatum

            let poolSmartManagerNFTAssetName =
              safe_list_at(poolSmartManagerNFTAssetNames, index)

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
                poolSmartManagerPolicyId,
                poolSmartManagerNFTAssetName,
              ) == 1,
              quantity_of(
                self.mint,
                poolSmartManagerPolicyId,
                poolSmartManagerNFTAssetName,
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
        list.indexed_foldr(
          poolSmartManagerInputs,
          True,
          fn(index, input, result) {
            //As all inputs must return True, if any of previous input returned False, then fail
            //The last input is not checked but will return its value at the end, so if False withdraw will fail
            expect result

            expect InlineDatum(inputDatum) = input.output.datum
            expect PoolSmartManagerDatum { poolOwnerAuth, .. } = inputDatum

            let poolManagerOutput = safe_list_at(poolManagerOutputs, index)

            //Ensure the output has the correct datum type
            expect InlineDatum(outputDatum) = poolManagerOutput.datum
            expect PoolSmartManagerDatum { .. } = outputDatum

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
      CompoundLiquidity { lenderSmartWalletWithdrawRedeemerIndex } -> {
        //CompoundLiquidity action must be executed
        let lenderSmartWalletWithdrawRedeemer =
          safe_list_at(self.redeemers, lenderSmartWalletWithdrawRedeemerIndex)
        expect
          lenderSmartWalletWithdrawRedeemer.1st == Withdraw(
            Script(lenderSmartWalletWithdrawScriptHash),
          )
        expect lenderSmartWalletRedeemer: LenderSmartWalletWithdrawRedeemer =
          lenderSmartWalletWithdrawRedeemer.2nd

        when lenderSmartWalletRedeemer.action is {
          lsw.CompoundLiquidity { .. } -> True
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
  redeemer: PoolSmartManagerMintRedeemer,
  policy_id: PolicyId,
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  poolManagerSpendScriptHash: ByteArray,
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
  let poolSmartManagerMintedNFTs =
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
    list.indexed_foldr(
      poolSmartManagerMintedNFTs,
      True,
      fn(index, Pair(assetName, quantity), result) {
        expect result

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
        expect PoolSmartManagerDatum { .. } = outputDatum

        and {
          quantity == 1,
          outputHasUniqueToken,
          correctAddress,
        }
      },
    )

  let poolMintedNFTs = dict.to_pairs(tokens(self.mint, poolPolicyId))
  //NOTE: We don't check the destination of the minted NFTs, as it's the pool owner interest to put them in this SC
  //When you mint a pool you also mint this NFT with same AssetName
  //When you cancel (burn) a pool you also burn this NFT
  and {
    length(poolInputs) == 0,
    poolSmartManagerMintedNFTs == poolMintedNFTs,
    isEachMintedTokenAccountedFor,
  }
}
