use fluidtokens/types/general.{AuthorizationMethod}

pub type PoolSmartManagerDatum {
  poolOwnerAuth: AuthorizationMethod,
  poolId: ByteArray,
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
