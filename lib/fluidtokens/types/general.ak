use cardano/assets.{AssetName, PolicyId}

pub type Asset {
  policyId: PolicyId,
  assetName: AssetName,
}

pub type CollateralAsset {
  policyId: PolicyId,
  maybeAssetName: Option<AssetName>,
  maybeOracleTokenAsset: Option<Asset>,
}

pub type AuthorizationMethod {
  CardanoSignature
  CardanoSpendScript
  CardanoWithdrawScript
  CardanoMintScript
}

pub type Authorization {
  method: AuthorizationMethod,
  hash: ByteArray,
}
