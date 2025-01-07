use cardano/address.{Address}
use cardano/transaction.{OutputReference}
use fluidtokens/types/datum.{LiquidationMode}
use fluidtokens/types/general.{Asset, AuthorizationMethod}

pub type CommonFeedData {
  valid_from: Int,
  valid_to: Int,
  token: Asset,
}

pub type OraclePriceFeed {
  //Tokens that have a lot of liquidity are in CEX. The price is in lovelace
  Aggregated {
    common: CommonFeedData,
    token_price_in_lovelaces: Int,
    denominator: Int,
  }
  //Tokens that have lower liquidity, AMM pool data is used to calculate the price
  Pooled {
    common: CommonFeedData,
    token_a_amount_in_pool: Int,
    token_b_amount_in_pool: Int,
  }
  //Complex vaults can have a dedicated oracle that calculates the value of all collateral assets in a custom currency
  Dedicated {
    common: CommonFeedData,
    token_price_currency: Asset,
    token_price: Int,
    denominator: Int,
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
    //Asset that the borrower is providing, must be accepted by the pool
    chosenCollateralIndex: Int,
    //If collateral doesn't use oracle, this must be -1
    chosenCollateralOracleInputIndex: Int,
    wantedPrincipal: Int,
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
  inputRef: OutputReference,
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
    //Used only when an auction must start as part of liquidation
    lenderAuthHash: AuthorizationMethod,
    //Used only when an auction must start as part of liquidation
    lenderAddress: Address,
    //Only for partialLiquidation, it's collateralValue - remainingDebt
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
    addedCollateralAmount: Int,
    loanId: ByteArray,
  }
  //Borrower action
  Recast { bondInputIndex: Int, principalPaid: Int, loanId: ByteArray }
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
