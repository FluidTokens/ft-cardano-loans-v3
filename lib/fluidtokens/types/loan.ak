use cardano/assets.{AssetName}
use fluidtokens/types/general.{
  Asset, AuthorizationMethod, CollateralAsset, LiquidationMode, RepaymentMode,
}

pub type LoanDatum {
  repaidInstallments: Int,
  //Principal taken with the loan expressed in units, for example 100ADA -> 100000000
  doneRecasts: Int,
  principalAmount: Int,
  //The interest rate of the loan is this number/10000, so 0.01% is expressed as 1.
  //For perpetuals this variable actually represents c in the formula APY=mx+c, and it can be used for:
  //installmentAmount (hourly) = c/10000/8760
  interestRate: Int,
  //Total number of installments, ignored in Perpetual loans
  totalInstallments: Int,
  principalAsset: Asset,
  //Used in dynamicPriced pools and in partial liquidations, it indicates the oracle NFT for the principal
  principalOracleAsset: Asset,
  //How much time between 2 consecutive installments, expressed in hours
  //In case of Perpetual loans if it's > 0 it means we have infinite installments otherwise == 0 means no installments
  installmentPeriod: Int,
  //Period after starting the loan and before starting repaying (borrower can't be liquidated in this period)
  //Expressed in hours
  initialGracePeriod: Int,
  liquidationMode: LiquidationMode,
  repaymentMode: RepaymentMode,
  //Period to repay without being considered late, expressed in hours
  //After this period, borrower can be liquidated if he hasn't paid the installment
  repaymentTimeWindow: Int,
  //Fee borrower pays when he could be liquidated but he repays, <= 0 means no penalty
  penaltyFeeForLateRepayment: Int,
  //If true, each payment for claim, recast and repay must be accompanied by a minted repayment receipt NFT
  repaymentReceipts: Bool,
  //Either the poolId or the requestId
  originId: AssetName,
  collateral: CollateralAsset,
  //Expressed in millis POSIX
  lendDate: Int,
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
  //Position in Value of the borrower bond PolicyId
  borrowerBondRefInputPolicyIdIndex: Int,
  //Position in Value of the borrower bond AssetName
  borrowerBondRefInputAssetNameIndex: Int,
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
  lenderBondRefInputPolicyIdIndex: Int,
  lenderBondRefInputAssetNameIndex: Int,
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
  lenderBondRefInputPolicyIdIndex: Int,
  lenderBondRefInputAssetNameIndex: Int,
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
