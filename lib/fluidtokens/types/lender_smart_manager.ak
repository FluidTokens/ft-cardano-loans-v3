use cardano/address.{StakeCredential}
use fluidtokens/types/general.{Asset, AuthorizationMethod}

pub type LenderSmartManagerDatum {
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

pub type LenderSmartManagerAction {
  //Lender can withdraw his bond any time
  WithdrawBonds
  //Lender can get his assets that point to his bond as long as the bond is in this contract
  WithdrawAssets
  //Liquidate loans and put the collaterals in this contract
  Liquidate
  //Compound available assets into the pool
  Compound
  //Liquidate loans and pay in advance the corresponding principal in exchange for the collateral
  LiquidateAndPayInAdvance
  //Liquidate loans and convert the collateral to principal
  LiquidateAndConvert
  //Liquidate + pay in advance + compound 
  LiquidatePayInAdvanceAndCompound
  //Liquidate + convert + compound
  LiquidateConvertAndCompound
}

pub type LenderSmartManagerWithdrawRedeemer {
  configRefInputIndex: Int,
  action: LenderSmartManagerAction,
}

pub type LSMWithdrawBondsWithdrawRedeemer {
  configRefInputIndex: Int,
}

pub type LSMWithdrawAssetsWithdrawRedeemer {
  configRefInputIndex: Int,
  lenderBondInputIndexes: List<Int>,
}

pub type LSMLiquidateWithdrawRedeemer {
  configRefInputIndex: Int,
  lenderBondInputIndexes: List<Int>,
  lenderBondAssetNames: List<ByteArray>,
}

pub type LSMCompoundWithdrawRedeemer {
  configRefInputIndex: Int,
  lenderBondInputIndexes: List<Int>,
  compoundedPoolNewIds: List<ByteArray>,
}

pub type LSMLiquidateAndPayInAdvanceWithdrawRedeemer {
  configRefInputIndex: Int,
  lenderBondInputIndexes: List<Int>,
  lenderBondAssetNames: List<ByteArray>,
  principalAndCollateralOracleRefInputIndexes: List<(Int, Int)>,
}

pub type LSMLiquidateAndConvertActionWithdrawRedeemer {
  configRefInputIndex: Int,
  lenderBondInputIndexes: List<Int>,
  lenderBondAssetNames: List<ByteArray>,
  minswapRefInputindexes: List<Int>,
  minswapPoolAssetNames: List<ByteArray>,
}

pub type LSMLiquidatePayInAdvanceAndCompoundWithdrawRedeemer {
  configRefInputIndex: Int,
  lenderBondInputIndexes: List<Int>,
  lenderBondAssetNames: List<ByteArray>,
  principalAndCollateralOracleRefInputIndexes: List<(Int, Int)>,
  compoundedPoolNewIds: List<ByteArray>,
}

pub type LSMLiquidatConvertAndCompoundWithdrawRedeemer {
  configRefInputIndex: Int,
  lenderBondInputIndexes: List<Int>,
  lenderBondAssetNames: List<ByteArray>,
  minswapV2InfoRefInputIndex: Int,
  compoundedPoolNewIds: List<ByteArray>,
}
