use fluidtokens/types/general.{Asset}

pub type CommonFeedData {
  valid_from: Int,
  valid_to: Int,
  token: Asset,
}

//Each oracle returns info about a pair customTokenSmallestUnit/lovelace.
//There are NO pairs tokenASmallestUnit/tokenBSmallestUnit.
//If the loan and the collateral are two custom tokens, we use 2 oracles: 
//tokenASmallestUnit/lovelace and tokenBSmallestUnit/lovelace.
//We always convert into lovelace to do calculations and eventually we convert it back
pub type OraclePriceFeed {
  //Tokens that have a lot of liquidity are in CEX. The price is in lovelace
  Aggregated {
    common: CommonFeedData,
    //How much 1 token is worth in lovelace. If 1 token = 0,00043 lovelace then the value here is 43
    token_price_in_lovelaces: Int,
    //If 1 token = 0,00043 lovelace then the value here is 100000
    token_price_denominator: Int,
  }
  //For tokens that have lower liquidity, AMM pool data is used to calculate the price. token_b is always lovelace
  Pooled {
    common: CommonFeedData,
    token_a_amount_in_pool: Int,
    token_b_amount_in_pool: Int,
    //Fees expected to pay from the AMM pool. Put 3 for 0.3%
    pool_fees_per_mille: Int,
  }
  //When used as collateral, complex vaults (represented by a key token) and NFTs can have a dedicated oracle 
  //that calculates the total value in lovelace.
  Dedicated {
    common: CommonFeedData,
    price_in_lovelaces: Int,
    price_denominator: Int,
  }
}

pub type Signature {
  signature: ByteArray,
  key_position: Int,
}

pub type OracleRedeemer {
  data: OraclePriceFeed,
  signatures: List<Signature>,
}
