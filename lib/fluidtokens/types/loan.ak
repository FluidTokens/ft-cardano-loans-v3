use cardano/assets.{AssetName}
use fluidtokens/types/general.{AuthorizationMethod, CollateralAsset}
use fluidtokens/types/pool.{CommonData, LiquidationMode, RepaymentMode}

pub type LoanDatum {
  commonData: CommonData,
  //Total number of installments, ignored in Perpetual loans
  totalInstallments: Int,
  //Either the poolId or the requestId
  originId: AssetName,
  collateral: CollateralAsset,
  //Principal taken with the loan expressed in units, for example 100ADA -> 100000000
  principalAmount: Int,
  //Expressed in millis POSIX
  lendDate: Int,
  repaidInstallments: Int,
  doneRecasts: Int,
}

pub type LoanMintRedeemer {
  configRefInputIndex: Int,
  //True if comes from pool, false if comes from request
  isPoolOrigin: Bool,
  originWithdrawRedeemerIndex: Int,
}

pub type ActionType {
  //Lender action (or anyone who has the permission to spend the lender's bond)
  Claim
  //Borrower action
  Repay
  //Borrower action
  ChangeCollateral
  //Borrower action
  Recast
}

pub type LoanWithdrawRedeemer {
  configRefInputIndex: Int,
  actionType: ActionType,
}

pub type ClaimData {
  //Must be the same value of the one contained in the datum, used by repayment validator
  liquidationMode: LiquidationMode,
  //This is the absolute output index that contains the lender bond
  lenderBondOutputIndex: Int,
  //This is the absolute ref input index that contains the borrower bond
  borrowerBondRefInputIndex: Int,
  //If loan doesn't use oracle, this is not used
  collateralOracleRefInputIndex: Int,
  //If loan doesn't use oracle, this is not used
  principalOracleRefInputIndex: Int,
  //Used only when an auction must start as part of liquidation
  lenderAuth: AuthorizationMethod,
  //Only for partialLiquidation, it's collateralValue - remainingDebt expressed in principal currency
  equity: Int,
  loanId: ByteArray,
}

pub type RepayData {
  //This is the absolute output index that contains the borrower bond
  borrowerBondOutputIndex: Int,
  lenderBondRefInputIndex: Int,
  loanId: ByteArray,
  //Used only in Perpetual Loans to signal the last repayment that will close the loan
  isFinalRepayment: Bool,
}

pub type ChangeCollateralData {
  borrowerBondOutputIndex: Int,
  //Units of collateral that remain in the loan after the change
  newCollateralAmount: Int,
  loanId: ByteArray,
  collateralOracleRefInputIndex: Int,
  principalOracleRefInputIndex: Int,
}

pub type RecastData {
  borrowerBondOutputIndex: Int,
  lenderBondRefInputIndex: Int,
  //In principal units
  principalPaid: Int,
  loanId: ByteArray,
}

pub type LoanClaimActionWithdrawRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<ClaimData>,
}

pub type LoanRepayActionWithdrawRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<RepayData>,
}

pub type LoanChangeCollateralActionWithdrawRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<ChangeCollateralData>,
}

pub type LoanRecastActionWithdrawRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<RecastData>,
}

pub type LoanRepaymentData {
  loanId: ByteArray,
  principalAmount: Int,
  interestRate: Int,
  repaidInstallments: Int,
  totalInstallments: Int,
  repaymentMode: RepaymentMode,
}
