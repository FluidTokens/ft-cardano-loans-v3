//Common pools produce LP tokens that represent a share of the pool.
//It support only perpetual loans with full liquidation.
//Repayments accumulate here in separated utxos, therefore anyone can aggregate them and provide liquidity to the pool.
//Liquidated collateral is also accumulated here in separated utxos, therefore anyone can aggregate them, swap them on Minswap and
//provide liquidity to the pool.
use cardano/address.{Address}
use cardano/transaction.{OutputReference}
use fluidtokens/types/general.{Asset}

pub type CommonPoolDatum {
  poolId: ByteArray,
  principalAsset: Asset,
  claimingFeePerMille: Int,
  compoundingFeePerMille: Int,
  swappingFeePerMille: Int,
  lpTokensInCirculation: Int,
}

pub type CommonPoolAction {
  PoolCreation
  DepositOrWithdraw
  ClaimLoans
  CompoundLiquidity
  SwapAssetsToLiquidity
}

pub type CommonPoolWithdrawRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<CommonPoolAction>,
}
