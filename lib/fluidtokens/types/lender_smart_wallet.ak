//Common pools produce LP tokens that represent a share of the pool.
//It support only perpetual loans with full liquidation.
//Repayments accumulate here in separated utxos, therefore anyone can aggregate them and provide liquidity to the pool.
//Liquidated collateral is also accumulated here in separated utxos, therefore anyone can aggregate them, swap them on Minswap and
//provide liquidity to the pool.
use cardano/address.{Address}
use cardano/transaction.{OutputReference}
use fluidtokens/types/general.{
  Asset, AuthorizationMethod, CollateralAsset, LiquidationMode, RepaymentMode,
}

pub type LenderSmartWalletDatum {
  lenderAuth: AuthorizationMethod,
  //If it's "" it means no compouding allowed
  poolId: ByteArray,
  //The repaid/liquidated loan must have the same principal of the specified pool
  principalAsset: Asset,
  claimingFeeInLovelace: Int,
  swappingFeePerMille: Int,
  compoundingFeePerMille: Int,
}

pub type LenderSmartWalletAction {
  Cancel
  //Withdraws can be done only after cancelling (getting lender bond back)
  Withdraw { lenderBondOutputIndexes: List<Int> }
  ClaimLoans {
    lenderBondOutputIndexes: List<Int>,
    claimedCollateralOutputIndexes: List<Int>,
    loanIds: List<ByteArray>,
  }
  ConvertToLiquidity {
    lenderBondRefInputsIndexes: List<Int>,
    minswapOrderOutputIndexes: List<Int>,
  }
  CompoundLiquidity {
    lenderBondRefInputIndexes: List<Int>,
    compoundedPoolInputsIndexes: List<Int>,
    compoundedPoolOutputsIndexes: List<Int>,
    compoundedPoolNewIds: List<ByteArray>,
  }
}

pub type LenderSmartWalletWithdrawRedeemer {
  configRefInputIndex: Int,
  action: LenderSmartWalletAction,
}
