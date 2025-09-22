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
  //If false, the collateral must not be converted to principal during liquidations
  shouldLiquidationConvertToPrincipal: Bool,
  //How much the bot gets of the liquidated collateral, expressed in per mille (1/1000)
  liquidationFeePerMille: Int,
  //If "", no compouding is allowed
  poolManagerId: ByteArray,
  //The repaid/liquidated loan must have the same principal of the specified pool
  principalAsset: Asset,
}

pub type LenderSmartWalletAction {
  //Lender can withdraw his bond any time
  WithdrawBonds
  //Lender can get his assets that point to his bond as long as the bond is in this contract
  WithdrawAssets { lenderBondInputIndexes: List<Int> }
  //Liquidate loans and put the collaterals in this contract
  Liquidate {
    lenderBondInputIndexes: List<Int>,
    lenderBondAssetNames: List<ByteArray>,
  }
  //Compound available assets into the pool
  Compound {
    lenderBondInputIndexes: List<Int>,
    compoundedPoolNewIds: List<ByteArray>,
  }
  //Liquidate loans and pay in advance the corresponding principal in exchange for the collateral
  LiquidateAndPayInAdvance {
    lenderBondInputIndexes: List<Int>,
    lenderBondAssetNames: List<ByteArray>,
    principalAndCollateralOracleRefInputIndexes: List<(Int, Int)>,
  }
  //Liquidate loans and convert the collateral to principal
  LiquidateAndConvert {
    lenderBondInputIndexes: List<Int>,
    loanIds: List<ByteArray>,
    minswapV2InfoRefInputIndex: Int,
  }
  //Liquidate + pay in advance + compound 
  LiquidatePayInAdvanceAndCompound {
    loanInputIndexes: List<Int>,
    loanIds: List<ByteArray>,
    lenderBondInputIndexesForClaimedLoans: List<Int>,
    lenderBondInputIndexesForLSWAssets: List<Int>,
    principalAndCollateralOracleRefInputIndexes: List<(Int, Int)>,
    compoundedPoolNewIds: List<ByteArray>,
  }
  //Liquidate + convert + compound
  LiquidateConvertAndCompound {
    loanInputIndexes: List<Int>,
    loanIds: List<ByteArray>,
    lenderBondInputIndexes: List<Int>,
    minswapV2InfoRefInputIndex: Int,
    compoundedPoolNewIds: List<ByteArray>,
  }
}

pub type LenderSmartWalletWithdrawRedeemer {
  configRefInputIndex: Int,
  action: LenderSmartWalletAction,
}

pub type LSMWithdrawBondsWithdrawRedeemer {
  configRefInputIndex: Int,
}

pub type LSMWithdrawAssetsWithdrawRedeemer {
  configRefInputIndex: Int,
  lenderBondInputIndexes: List<Int>,
}
