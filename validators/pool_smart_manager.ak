use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use cardano/address.{Address, Credential, Script}
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Input, Output, Transaction, Withdraw}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/lender_smart_wallet.{LenderSmartWalletWithdrawRedeemer} as lsw
use fluidtokens/types/pool_smart_manager.{
  CancelPools, CompoundLiquidity, PoolSmartManagerDatum,
  PoolSmartManagerMintRedeemer, PoolSmartManagerWithdrawRedeemer,
}
use fluidtokens/utils.{safe_list_at}

validator poolSmartManager(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  poolSmartManagerSpendScriptHash: ByteArray,
  lenderSmartWalletWithdrawScriptHash: ByteArray,
) {
  mint(
    redeemer: PoolSmartManagerMintRedeemer,
    policy_id: PolicyId,
    self: Transaction,
  ) {
    check_mint(self, redeemer, policy_id, configNFTPolicyId, configNFTAssetName)
  }

  withdraw(
    redeemer: PoolSmartManagerWithdrawRedeemer,
    _credential: Credential,
    self: Transaction,
  ) {
    let config =
      utils.get_config_as_data_list(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let poolPolicyId = builtin.un_b_data(utils.safe_list_at(config, 2))
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
      CancelPools ->
        list.indexed_foldr(
          poolSmartManagerInputs,
          True,
          fn(_index, input, result) {
            //As all inputs must return True, if any of previous input returned False, then fail
            //The last input is not checked but will return its value at the end, so if False withdraw will fail
            expect result

            expect InlineDatum(inputDatum) = input.output.datum
            expect PoolSmartManagerDatum { poolOwnerAuth, poolSmartManagerNFT } =
              inputDatum

            and {
              authorize_action(
                create_auth(
                  poolOwnerAuth,
                  self.inputs,
                  self.withdrawals,
                  self.extra_signatories,
                  self.mint,
                ),
              ),
              quantity_of(self.mint, poolPolicyId, poolSmartManagerNFT) == -1,
            }
          },
        )
      CompoundLiquidity { lenderSmartWalletWithdrawRedeemerIndex } ->
        list.indexed_foldr(
          poolSmartManagerInputs,
          True,
          fn(_index, input, result) {
            //As all inputs must return True, if any of previous input returned False, then fail
            //The last input is not checked but will return its value at the end, so if False withdraw will fail
            expect result

            expect InlineDatum(inputDatum) = input.output.datum
            expect PoolSmartManagerDatum { poolSmartManagerNFT, .. } =
              inputDatum

            let lenderSmartWalletWithdrawRedeemer =
              safe_list_at(
                self.redeemers,
                lenderSmartWalletWithdrawRedeemerIndex,
              )
            expect
              lenderSmartWalletWithdrawRedeemer.1st == Withdraw(
                Script(lenderSmartWalletWithdrawScriptHash),
              )
            expect lenderSmartWalletRedeemer: LenderSmartWalletWithdrawRedeemer =
              lenderSmartWalletWithdrawRedeemer.2nd

            let lwsCompoundLiquidityCalled =
              when lenderSmartWalletRedeemer.action is {
                lsw.CompoundLiquidity { .. } -> True
                _ -> False
              }

            and {
              lwsCompoundLiquidityCalled,
              quantity_of(self.mint, poolPolicyId, poolSmartManagerNFT) == -1,
            }
          },
        )
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
) {
  let config =
    utils.get_config_as_data_list(
      safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
      configNFTPolicyId,
      configNFTAssetName,
    )
  let poolPolicyId = builtin.un_b_data(utils.safe_list_at(config, 2))

  let poolSmartManagerMintedNFTs = dict.to_pairs(tokens(self.mint, policy_id))

  let poolMintedNFTs = dict.to_pairs(tokens(self.mint, poolPolicyId))
  //When you mint a pool you also mint this NFT
  //When you cancel (burn) a pool you also burn this NFT
  poolSmartManagerMintedNFTs == poolMintedNFTs
}
