use aiken/builtin
use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/transaction.{Transaction}
use fluidtokens/types/lender_manager.{
  Compound, LenderManagerWithdrawRedeemer, Liquidate, LiquidateAndConvert,
  LiquidateAndPayInAdvance, LiquidateConvertAndCompound,
  LiquidatePayInAdvanceAndCompound, WithdrawAssets, WithdrawBonds,
} as lm
use fluidtokens/utils.{safe_list_at}

validator lenderManager(
  lmConfigNFTPolicyId: ByteArray,
  lmConfigNFTAssetName: ByteArray,
) {
  withdraw(
    redeemer: LenderManagerWithdrawRedeemer,
    _credential: Credential,
    self: Transaction,
  ) {
    let lmConfig =
      utils.get_config_as_data_list(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        lmConfigNFTPolicyId,
        lmConfigNFTAssetName,
      )
    let lmWithdrawBondsActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(lmConfig, 1))
    let lmWithdrawAssetsActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(lmConfig, 2))
    let lmLiquidateActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(lmConfig, 3))
    let lmCompoundActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(lmConfig, 4))
    let lmLiquidateAndPayInAdvanceActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(lmConfig, 5))
    let lmLiquidateAndConvertActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(lmConfig, 6))
    let lmLiquidatePayInAdvanceAndCompoundActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(lmConfig, 7))
    let lmLiquidateConvertAndCompoundActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(lmConfig, 8))
    let actionWithdrawScriptHash =
      when redeemer.action is {
        WithdrawBonds -> lmWithdrawBondsActionScriptHash
        WithdrawAssets { .. } -> lmWithdrawAssetsActionScriptHash
        Liquidate { .. } -> lmLiquidateActionScriptHash
        Compound { .. } -> lmCompoundActionScriptHash
        LiquidateAndPayInAdvance { .. } ->
          lmLiquidateAndPayInAdvanceActionScriptHash
        LiquidateAndConvert { .. } -> lmLiquidateAndConvertActionScriptHash
        LiquidatePayInAdvanceAndCompound { .. } ->
          lmLiquidatePayInAdvanceAndCompoundActionScriptHash
        LiquidateConvertAndCompound { .. } ->
          lmLiquidateConvertAndCompoundActionScriptHash
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
