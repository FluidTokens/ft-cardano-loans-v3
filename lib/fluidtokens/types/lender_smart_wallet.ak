//Common pools produce LP tokens that represent a share of the pool.
//It support only perpetual loans with full liquidation.
//Repayments accumulate here in separated utxos, therefore anyone can aggregate them and provide liquidity to the pool.
//Liquidated collateral is also accumulated here in separated utxos, therefore anyone can aggregate them, swap them on Minswap and
//provide liquidity to the pool.
use cardano/address.{StakeCredential}
use fluidtokens/types/general.{Asset, AuthorizationMethod}

pub type LenderSmartWalletMintRedeemer {
  configRefInputIndex: Int,
}

pub type LenderSmartWalletDatum {
  //Auth to get the lender bond back
  lenderAuth: AuthorizationMethod,
  //Stake credential of the lender, used for any utxo created by the bots
  lenderStakeCredential: Option<StakeCredential>,
  //If it's "" it means no compouding allowed
  poolManagerId: ByteArray,
  //The repaid/liquidated loan must have the same principal of the specified pool
  principalAsset: Asset,
}

pub type LenderSmartWalletAction {
  WithdrawBonds
  //Withdraws can be done only after cancelling (getting lender bond back)
  WithdrawAssets { lenderBondOutputIndexes: List<Int> }
  LiquidatePayInAdvanceAndCompound {
    loanInputIndexes: List<Int>,
    loanIds: List<ByteArray>,
    lenderBondInputsIndexesForClaimedLoans: List<Int>,
    lenderBondInputsIndexesForLSWAssets: List<Int>,
    compoundedPoolNewIds: List<ByteArray>,
  }
  LiquidateConvertAndCompound {
    loanInputIndexes: List<Int>,
    loanIds: List<ByteArray>,
    lenderBondInputsIndexes: List<Int>,
    minswapV2InfoRefInputIndex: Int,
    compoundedPoolNewIds: List<ByteArray>,
  }
}

pub type LenderSmartWalletWithdrawRedeemer {
  configRefInputIndex: Int,
  action: LenderSmartWalletAction,
}
