use aiken/hash.{Blake2b_224, Hash}
use aiken/transaction/credential.{Address, VerificationKey}
use aiken/transaction/value.{AssetName, PolicyId, Value}

pub type Asset {
  policyId: PolicyId,
  assetName: AssetName,
}

pub type CollateralAsset {
  policyId: PolicyId,
  maybeAssetName: Option<AssetName>,
  oracleTokenAsset: Option<Asset>,
}

pub type VerificationKeyHash =
  Hash<Blake2b_224, VerificationKey>
