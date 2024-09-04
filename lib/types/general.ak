use aiken/crypto.{Blake2b_224, Hash}
use cardano/address.{Address}
use cardano/assets.{AssetName, PolicyId, Value}

pub type Asset {
  policyId: PolicyId,
  assetName: AssetName,
}

pub type CollateralAsset {
  policyId: PolicyId,
  maybeAssetName: Option<AssetName>,
  oracleTokenAsset: Option<Asset>,
}
