use fluidtokens/types/general.{AuthorizationMethod}

pub type PoolManagerDatum {
  //Who can use this PoolManager to cancel/edit the pool
  poolOwnerAuth: AuthorizationMethod,
  //Id of the pool controlled by this PoolManager.
  //When a pool is edited (cancel+recreate) or when a compound happens, the pool NFT changes.
  //During the edit, the poolManager NFT must be burnt and recreated.
  //During the compound, the poolManager NFT stays the same and poolId field is updated.
  //Even if a poolId points to a pool that it's not yours, you can at max add assets to that pool,
  //because to cancel/edit the pool you need the poolOwnerAuth.
  poolId: ByteArray,
  //How much the bot gets of the compounded principal, expressed in per mille (1/1000)
  compoudingFeePerMille: Int,
}

pub type PoolManagerMintRedeemer {
  configRefInputIndex: Int,
}

pub type PoolManagerAction {
  //As a pool can delegate auth to this withdraw script, we must allow to cancel the pools
  CancelPoolManager { poolSmartManagerNFTAssetNames: List<ByteArray> }
  //Update only the datum that must still have the correct type
  UpdatePoolManager
  //Delegates the security to one of the compounding actions from LenderManager
  CompoundLiquidity { lenderSmartManagerWithdrawRedeemerIndex: Int }
}

pub type PoolManagerWithdrawRedeemer {
  configRefInputIndex: Int,
  action: PoolManagerAction,
}
