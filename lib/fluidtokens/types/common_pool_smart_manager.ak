//Common pools produce LP tokens that represent a share of the pool.
//It support only perpetual loans with full liquidation.
//Repayments accumulate here in separated utxos, therefore anyone can aggregate them and provide liquidity to the pool.
//Liquidated collateral is also accumulated here in separated utxos, therefore anyone can aggregate them, swap them on Minswap and
//provide liquidity to the pool.
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
  Cancel
  //Withdraws can be done only after cancelling (getting lender bond back)
  Withdraw { lenderBondOutputIndexes: List<Int> }
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

pub type CommonPoolWithdrawRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<CommonPoolAction>,
}
