use cardano/assets.{AssetName}
use fluidtokens/types/general.{AuthorizationMethod, CollateralAsset}
use fluidtokens/types/pool.{CommonData, LiquidationMode}

pub type LoanDatum {
  commonData: CommonData,
  //Either the poolId or the requestId
  originAssetName: AssetName,
  borrowerAssetName: AssetName,
  lenderAssetName: AssetName,
  collateral: CollateralAsset,
  //Principal taken with the loan expressed in units, for example 100ADA -> 100000000
  principalAmount: Int,
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

pub type LoanAction {
  //Lender action (or anyone who has the permission to spend the lender's bond)
  Claim {
    //Must be the same value of the one contained in the datum, used by repayment validator
    liquidationMode: LiquidationMode,
    //This is the absolute input index that contains the lender bond
    lenderBondInputIndex: Int,
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
  //Borrower action
  Repay {
    //This is the absolute input index that contains the borrower bond
    borrowerBondInputIndex: Int,
    loanId: ByteArray,
    //Used only in Perpetual Loans to signal the last repayment that will close the loan
    isFinalRepayment: Bool,
  }
  //Borrower action
  ChangeCollateral {
    borrowerBondInputIndex: Int,
    //Units of collateral that remain in the loan after the change
    newCollateralAmount: Int,
    loanId: ByteArray,
    collateralOracleRefInputIndex: Int,
    principalOracleRefInputIndex: Int,
  }
  //Borrower action
  Recast {
    borrowerBondInputIndex: Int,
    //In principal units
    principalPaid: Int,
    loanId: ByteArray,
  }
}

pub type LoanWithdrawRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<LoanAction>,
}
