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
//TODO chiede il formato di oracoli Butane
//TODO aggiungi field di liquidazione nel datum pool
