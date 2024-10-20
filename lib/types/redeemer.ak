use cardano/address.{Address}
use types/general.{Asset, Authorization}

pub type PoolSpendRedeemer {
  Cancel { auth: Authorization }
  Borrow { withdrawIndex: Int }
}

pub type PoolAction {
  borrowerAddress: Address,
  outputWithLenderTokenIndex: Int,
  //Asset that the borrower is providing, must be accepted by the pool
  chosenCollateralIndex: Int,
  //If collateral doesn't use oracle, this must be -1
  chosenCollateralOracleInputIndex: Int,
  wantedPrincipal: Int,
}

pub type PoolWithdrawRedeemer {
  actionForEachInput: List<PoolAction>,
}

//Tokens that have a lot of liquidity is in CEX. The price is in lovelace
pub type AggregatedFeed {
  token: Asset,
  token_price_in_lovelaces: Int,
  denominator: Int,
  valid_to: Int,
}

//Tokens that have lower liquidity and AMM pool data is used to calculate the price
pub type PooledFeed {
  token: Asset,
  token_a_amount: Int,
  token_b_amount: Int,
  valid_to: Int,
}

//Complex vaults can have a dedicated oracle that calculates the value of all collateral assets in a custom currency
pub type DedicatedFeed {
  token: Asset,
  token_price_currency: Asset,
  token_price: Int,
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

pub type ActiveAction {
  //Lender action (or anyone who has the permission to spend the lender's bond)
  Claim {
    //This is the absolute input index that contains the lender bond
    bondInputIndex: Int,
    //If loan doesn't use oracle, this is not used
    collateralOracleInputIndex: Int,
  }
  //Borrower action
  Repay {
    //This is the absolute input index that contains the borrower bond
    bondInputIndex: Int,
  }
  //Borrower action
  AddCollateral { bondInputIndex: Int, addedCollateralAmount: Int }
  //Borrower action
  Recast { bondInputIndex: Int, principalPaid: Int }
}

pub type ActiveWithdrawRedeemer {
  actionForEachInput: List<ActiveAction>,
}
