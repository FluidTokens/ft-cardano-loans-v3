use cardano/address.{Address}
use cardano/transaction.{OutputReference}
use fluidtokens/types/datum.{LiquidationMode}
use fluidtokens/types/general.{Asset, AuthorizationMethod}

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

pub type PoolMintRedeemer {
  configRefInputIndex: Int,
  inputRef: OutputReference,
}

pub type PoolAction {
  Cancel { poolId: ByteArray }
  Borrow {
    borrowerAddress: Address,
    outputWithLenderTokenIndex: Int,
    //Ref input index of the principal oracle, if principal is ADA this must be -1
    principalOracleRefInputIndex: Int,
    //Index of the Asset that the borrower is providing, must be accepted by the pool
    chosenCollateralIndex: Int,
    //If collateral doesn't use oracle or is ADA, this must be -1
    chosenCollateralOracleRefInputIndex: Int,
    //How much principal the borrower wants in units. 
    //For example if borrower wants 123 FLDT he must write 123000000 .
    //It cannot be completely arbitrary as pools allow only certain amounts.
    wantedPrincipalAmount: Int,
    poolId: ByteArray,
    permissionedConditionWithdrawIndex: Int,
  }
}

pub type PoolWithdrawRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<PoolAction>,
}

pub type LoanMintRedeemer {
  configRefInputIndex: Int,
  poolWithdrawRedeemerIndex: Int,
}

pub type LoanAction {
  //Lender action (or anyone who has the permission to spend the lender's bond)
  Claim {
    //Must be the same value of the one contained in the datum, used by repayment validator
    liquidationMode: LiquidationMode,
    //This is the absolute input index that contains the lender bond
    lenderBondInputIndex: Int,
    //If loan doesn't use oracle, this is not used
    collateralOracleInputIndex: Int,
    //If loan doesn't use oracle, this is not used
    principalOracleRefInputIndex: Int,
    //Used only when an auction must start as part of liquidation
    lenderAuth: AuthorizationMethod,
    //Used only when an auction must start as part of liquidation
    lenderAddress: Address,
    //Only for partialLiquidation, it's collateralValue - remainingDebt expressed in principal currency
    equity: Int,
    loanId: ByteArray,
  }
  //Borrower action
  Repay {
    //This is the absolute input index that contains the borrower bond
    bondInputIndex: Int,
    loanId: ByteArray,
  }
  //Borrower action
  AddCollateral {
    bondInputIndex: Int,
    //Units of collateral added to improve the health of the loan
    addedCollateralAmount: Int,
    loanId: ByteArray,
  }
  //Borrower action
  Recast {
    bondInputIndex: Int,
    //In principal units
    principalPaid: Int,
    loanId: ByteArray,
  }
}

pub type LoanWithdrawRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<LoanAction>,
}

pub type RepaymentMintRedeemer {
  configRefInputIndex: Int,
  inputRef: OutputReference,
  loanWithdrawRedeemerIndex: Int,
}

pub type RepaymentAction {
  WithdrawWithToken { tokenInputIndex: Int }
  WithdrawWithHash
}

pub type RepaymentWithdrawRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<(RepaymentAction, ByteArray)>,
}

pub type DutchAuctionAction {
  DA_Cancel
  DA_Buy
}

pub type DutchAuctionRedeemer {
  actionsForEachInput: List<DutchAuctionAction>,
}
