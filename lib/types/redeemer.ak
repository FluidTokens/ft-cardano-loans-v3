use aiken/hash.{Blake2b_224, Hash}
use aiken/transaction/credential.{Address, VerificationKey}
use aiken/transaction/value.{AssetName, PolicyId, Value}
use types/general.{Asset, CollateralAsset}

pub type OracleLTVPoolRedeemer {
  Cancel
  Accept {
    currentRequestInputIndex: Int,
    outputWithBorrowerTokenIndex: Int,
    outputWithLenderTokenIndex: Int,
    //Asset that the borrower is providing, must be accepted by the pool
    chosenCollateral: CollateralAsset,
    //If collateral doesn't use oracle, this must be -1
    chosenCollateralOracleInputIndex: Int,
    wantedPrincipal: Int,
  }
}

//Tokens that have a lot of liquidity is in CEX
pub type AggregatedFeed {
  token: Asset,
  token_price_in_lovelaces: Int,
  denominator: Int,
  valid_to: Int,
}

//Tokens that have lower liquidity and pool data is used to calculate the price
pub type PooledFeed {
  token: Asset,
  token_a_amount: Int,
  token_b_amount: Int,
  valid_to: Int,
}

//Complex vaults can have a dedicated oracle that calculates the sum of all collateral assets
pub type DedicatedFeed {
  tokens: Value,
  token_price_in_lovelaces: Int,
  denominator: Int,
  valid_to: Int,
}

pub type OraclePriceFeed {
  Aggregated(AggregatedFeed)
  Pooled(PooledFeed)
  Dedicated(DedicatedFeed)
}

pub type Signature {
  signature: ByteArray,
  key_position: Int,
}

pub type OracleRedeemer {
  data: OraclePriceFeed,
  signatures: List<Signature>,
}
