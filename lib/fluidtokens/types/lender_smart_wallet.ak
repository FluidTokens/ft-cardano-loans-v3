//Common pools produce LP tokens that represent a share of the pool.
//It support only perpetual loans with full liquidation.
//Repayments accumulate here in separated utxos, therefore anyone can aggregate them and provide liquidity to the pool.
//Liquidated collateral is also accumulated here in separated utxos, therefore anyone can aggregate them, swap them on Minswap and
//provide liquidity to the pool.
use cardano/address.{Address, StakeCredential}
use cardano/transaction.{OutputReference}
use fluidtokens/types/general.{
  Asset, AuthorizationMethod, CollateralAsset, LiquidationMode, RepaymentMode,
}

pub type LenderSmartWalletDatum {
  //Auth to get the lender bond back
  lenderAuth: AuthorizationMethod,
  //Stake credential of the lender, used for any utxo created by the bots
  lenderStakeCredential: Option<StakeCredential>,
  //If it's "" it means no compouding allowed
  poolId: ByteArray,
  //The repaid/liquidated loan must have the same principal of the specified pool
  principalAsset: Asset,
  //Fee per mille of the collateral asset for the bot that claims the loans collateral
  claimingFeePerMille: Int,
  //Fee per mille of the collateral asset for the bot that converts the loans collateral into principal
  swappingFeePerMille: Int,
  //Fee per mille of the principal asset for the bot that compounds the liquidity to the pool
  compoundingFeePerMille: Int,
}

pub type LenderSmartWalletAction {
  //As a pool can delegate auth to this withdraw script, we must allow to cancel the pools
  CancelPools
  WithdrawBonds
  //Withdraws can be done only after cancelling (getting lender bond back)
  WithdrawAssets { lenderBondOutputIndexes: List<Int> }
  ClaimLoans { loanIds: List<ByteArray> }
  ConvertToLiquidity {
    lenderBondRefInputsIndexes: List<Int>,
    minswapV2InfoRefInputIndex: Int,
  }
  CompoundLiquidity {
    lenderBondRefInputIndexes: List<Int>,
    compoundedPoolNewIds: List<ByteArray>,
  }
}

pub type LenderSmartWalletWithdrawRedeemer {
  configRefInputIndex: Int,
  action: LenderSmartWalletAction,
}
