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
//TODO Controllare che token nel redeemer dell'oracolo sia effettivamente quello voluto, altrimenti si spende un redeemer falso

//TODO Usare withdraw 0 nella Pool
