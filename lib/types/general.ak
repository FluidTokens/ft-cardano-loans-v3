use cardano/assets.{AssetName, PolicyId}

pub type Asset {
  policyId: PolicyId,
  assetName: AssetName,
}

pub type CollateralAsset {
  policyId: PolicyId,
  maybeAssetName: Option<AssetName>,
  oracleTokenAsset: Option<Asset>,
}
//TODO Usare withdraw 0 nella Pool
