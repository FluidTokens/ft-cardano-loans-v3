use fluidtokens/types/general.{AuthorizationMethod}

pub type PoolSmartManagerDatum {
  poolOwnerAuth: AuthorizationMethod,
  poolId: ByteArray,
  //How much the bot gets of the compounded principal, expressed in per mille (1/1000)
  compoudingFeePerMille: Int,
}

pub type PoolSmartManagerMintRedeemer {
  configRefInputIndex: Int,
}

pub type PoolSmartManagerAction {
  //As a pool can delegate auth to this withdraw script, we must allow to cancel the pools
  CancelPoolManager { poolSmartManagerNFTAssetNames: List<ByteArray> }
  UpdatePoolManager
  CompoundLiquidity { lenderSmartWalletWithdrawRedeemerIndex: Int }
}

pub type PoolSmartManagerWithdrawRedeemer {
  configRefInputIndex: Int,
  action: PoolSmartManagerAction,
}
