//NOT DONE: Deferment (with and without interest accruement)
//NOT DONE: Variable interest rate with oracle, eventual with min and max caps, eventual with first N installments at a fixed rate
//Margin calls are done off-chain as soon as the oracle signals a too-low LTV.
//Forgiveness in case of default is accomplished by sending the collateral back to the borrower in case of Full Collateral Claim.
//If the penalty fee should be sent to an address different from the lender, then the lender nft must be locked in a dedicated contract that says so.
//Loan refinancing is done spending the new loan and the old loan in the same tx.
use cardano/address.{Address}
use cardano/transaction.{OutputReference}
use fluidtokens/types/general.{Asset, AuthorizationMethod, CollateralAsset}

pub type RepaymentMode {
  //Amortization. Express number of possible recasts: 0 means no recasting, negative means unlimited
  InterestOnRemainingPrincipal { max_possible_recasts: Int }
  //Installment amount = Principal+Interest/Installments
  PrincipalAndInterestOnInstallments
  //These loans don't have a deadline, the borrower can repay whenever he wants
  //But the interest rate increases over time linearly and if installments are > 1 and they are not paid in time
  //the borrower can be liquidated
  //Liquidation for too low ltv is always possible if enabled
  //initialGracePeriod allows not to repay for a certain period after the loan starts but the interest rate keeps increasing!
  //Recasting is permitted when enabled
  //As the increase is linear, to know the interest rate (y) at a certain time (x), the formula is: y = A*x
  //Where A = interestRateIncreaseLinearCoefficient / interestRateIncreaseLinearCoefficientDivider
  PerpetualLoan {
    interestRateIncreaseLinearCoefficient: Int,
    interestRateIncreaseLinearCoefficientDivider: Int,
    max_possible_recasts: Int,
  }
}

pub type LiquidationMode {
  NoLiquidationFullCollateralClaim
  NoLiquidationDutchAuctionClaim
  Liquidation {
    lTV: Int,
    lTVDivider: Int,
    //If true, when claiming the collateral the lender must pay to the borrower the difference
    //If false, borrower loses all the collateral when liquidation happens
    partialLiquidation: Bool,
  }
}

pub type CommonData {
  principalAsset: Asset,
  //Used in dynamicPriced pools and in partial liquidations, it indicates the oracle NFT for the principal
  principalOracleAsset: Asset,
  //Per mille of the loan to repay to lender
  interestRate: Int,
  //How much time between 2 consecutive installments
  installmentPeriod: Int,
  totalInstallments: Int,
  //Period after starting the loan and before starting repaying (borrower can't be liquidated in this period)
  initialGracePeriod: Int,
  liquidationMode: LiquidationMode,
  repaymentMode: RepaymentMode,
  //Period to repay without being considered late
  //After this period, borrower can be liquidated if he hasn't paid the installment
  repaymentTimeWindow: Int,
  //Fee borrower pays when he could be liquidated but he repays, <= 0 means no penalty
  penaltyFeeForLateRepayment: Int,
}

pub type PoolDatum {
  commonData: CommonData,
  lenderAuth: AuthorizationMethod,
  lenderAddress: Address,
  //This pool can cover multiple collections/token, but only one of them can be chosen for each loan (ie. no mixed bundle loans).
  //Important requirement: if Liquidation is enabled, ALL the collateralOptions must have an oracle NFT
  collateralOptions: List<CollateralAsset>,
  //When oracle is used, this is the LTV for each collateral option (borrower can ask more using an exact multiple). 
  //This is the ration between principal and collateral when their value is expressed in lovelace.
  //For example, a LTV of 0.123 mean that principalInLovelace / collateralInLovelace = 0.123.
  //In this case, principalLTV = 123 and principalLTVDivider = 1000 .
  //If no oracle is used, then this is the collateral amount expressed in units of the token for each unit of principal.
  //For example, if the principal is lovelace and the collateral unitFLDT and lender wants 0.123 unitFLDT for each lovelace lent: 
  //principalLTV = 123 and principalLTVDivider = 1000 .
  principalLTV: List<Int>,
  principalLTVDivider: List<Int>,
  //True if borrowable amount of the collateralOptions must be updated through oracles
  dynamicCollateralPrice: Bool,
  //If true, the output of lender's bond contains LoanDatum, useful if the lender is a SC to do onchain validation.
  lenderTokenOutputMustHaveLoanDatum: Bool,
  //Permissioned pools use this field to specify an extra Withdraw validator to force the conditions of the Borrow action.
  //Put "NONE" if it's a permissionless pool
  permissionedConditionScriptHash: ByteArray,
  //Extend the pool datum for cases like permissioned pools. It will be parsed properly depending on specific use case.
  extraData: Data,
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
