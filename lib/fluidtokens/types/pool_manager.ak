use fluidtokens/types/general.{AuthorizationMethod}

pub type PoolManagerDatum {
  //Who can use this PoolManager to cancel/edit the pool
  poolOwnerAuth: AuthorizationMethod,
  //How much the bot gets of the compounded principal, expressed in per mille (1/1000)
  compoudingFeePerMille: Int,
}

pub type PoolManagerMintRedeemer {
  configRefInputIndex: Int,
  poolWithdrawRedeemerIndex: Int,
}

pub type PoolManagerAction {
  //As a pool can delegate auth to this withdraw script, we must allow to burn PMs
  CancelPoolManager
  //Update only the datum that must still have the correct type
  UpdatePoolManager
  //Delegates the security to one of the compounding actions from LenderManager
  CompoundLiquidity
}

pub type PoolManagerWithdrawRedeemer {
  configRefInputIndex: Int,
  action: PoolManagerAction,
}

pub type CancelPoolManagerActionWithdrawRedeemer {
  configRefInputIndex: Int,
  poolWithdrawRedeemerIndex: Int,
  poolManagerNFTAssetNames: List<ByteArray>,
}

pub type UpdatePoolManagerActionWithdrawRedeemer {
  configRefInputIndex: Int,
}

pub type CompoundLiquidityActionWithdrawRedeemer {
  configRefInputIndex: Int,
  poolWithdrawRedeemerIndex: Int,
  lenderManagerWithdrawRedeemerIndex: Int,
}
