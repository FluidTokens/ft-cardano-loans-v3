use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Credential}
use cardano/assets.{AssetName, PolicyId, Value}
use cardano/transaction.{Input}

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
  CardanoSignature { extra_signatories: List<VerificationKeyHash> }
  CardanoSpendScript { transaction_inputs: List<Input> }
  CardanoWithdrawScript { withdrawals: Pairs<Credential, Int> }
  CardanoMintScript { transaction_mint: Value }
}

pub type Authorization {
  method: AuthorizationMethod,
  hash: ByteArray,
}
