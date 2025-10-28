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

validator lenderSmartManager(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  withdraw(
    redeemer: LenderManagerWithdrawRedeemer,
    _credential: Credential,
    self: Transaction,
  ) {
    let config =
      utils.get_config_as_data_list(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let lmWithdrawBondsActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 1))
    let lmWithdrawAssetsActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 2))
    let lmLiquidateActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 3))
    let lmCompoundActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 4))
    let lmLiquidateAndPayInAdvanceActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 5))
    let lmLiquidateAndConvertActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 6))
    let lmLiquidatePayInAdvanceAndCompoundActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 7))
    let lmLiquidateConvertAndCompoundActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 8))
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
