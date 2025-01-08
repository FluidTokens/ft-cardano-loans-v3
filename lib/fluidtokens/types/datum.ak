//NOT DONE: Deferment (with and without interest accruement)
//NOT DONE: Variable interest rate with oracle, eventual with min and max caps, eventual with first N installments at a fixed rate
//Margin calls are done off-chain as soon as the oracle signals a too-low LTV.
//Forgiveness in case of default is accomplished by sending the collateral back to the borrower in case of Full Collateral Claim.
//If the penalty fee should be sent to an address different from the lender, then the lender nft must be locked in a dedicated contract that says so.
//Loan refinancing is done spending the new loan and the old loan in the same tx.
use cardano/address.{Address, Credential}
use cardano/assets.{AssetName}
use fluidtokens/types/general.{Asset, AuthorizationMethod, CollateralAsset}

pub type ConfigDatum {
  adminCredential: Credential,
  smartTokensSpendScriptHash: ByteArray,
  poolPolicyId: ByteArray,
  loanRequestPolicyId: ByteArray,
  borrowerBondPolicyId: ByteArray,
  lenderBondPolicyId: ByteArray,
  loanPolicyId: ByteArray,
  repaymentPolicyId: ByteArray,
  poolSpendScriptHash: ByteArray,
  loanRequestSpendScriptHash: ByteArray,
  loanSpendScriptHash: ByteArray,
  repaymentSpendScriptHash: ByteArray,
  dutchAuctionSpendScriptHash: ByteArray,
  dutchAuctionStartingIncreasePerMille: Int,
  dutchAuctionLoweringAmount: Int,
  dutchAuctionLoweringFrequency: Int,
  dutchAuctionMinPriceToCancel: Int,
}

pub type RepaymentMode {
  //Amortization. Express number of possible recasts: 0 means no recasting, negative means unlimited
  InterestOnRemainingPrincipal { max_possible_recasts: Int }
  //Installment amount = Principal+Interest/Installments
  PrincipalAndInterestOnInstallments
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

pub type RequestDatum {
  commonData: CommonData,
  borrowerAuthHash: AuthorizationMethod,
  borrowerAddress: Address,
  //This pool can cover multiple collections/tokens, but only one of them can be chosen for each loan (ie. no mixed bundle loans).
  //Important requirement: if liquidation is enabled, ALL the collateralOptions must have an oracle NFT
  collateralOptions: List<CollateralAsset>,
  //LTV for each collateral option (borrower can ask more using a multiple). If no oracle then this is the principal amount
  principalLTV: List<Int>,
  principalLTVDivider: List<Int>,
  //True if borrowable amount of the collateralOptions must be updated through oracles
  dynamicCollateralPrice: Bool,
}

pub type PoolDatum {
  commonData: CommonData,
  lenderAuthHash: AuthorizationMethod,
  lenderAddress: Address,
  //This pool can cover multiple collections/token, but only one of them can be chosen for each loan (ie. no mixed bundle loans).
  //Important requirement: if Liquidation is enabled, ALL the collateralOptions must have an oracle NFT
  collateralOptions: List<CollateralAsset>,
  //LTV for each collateral option (borrower can ask more using a multiple). If no oracle then this is the principal amount
  principalLTV: List<Int>,
  principalLTVDivider: List<Int>,
  //True if borrowable amount of the collateralOptions must be updated through oracles
  dynamicCollateralPrice: Bool,
  //If true, the output of lender's bond contains LoanInfoDatum, useful if the lender is a SC to do onchain validation.
  lenderTokenOutputMustHaveLoanInfoDatum: Bool,
  //Permissioned pools use this field to specify an extra Withdraw validator to force the conditions of the Borrow action.
  //Put "NONE" if it's a permissionless pool
  permissionedConditionScriptHash: ByteArray,
  //Extend the pool datum for cases like permissioned pools. It will be parsed properly depending on specific use case.
  extraData: Data,
}

//Optional datum of the lender's bond output 
pub type LoanInfoDatum =
  LoanDatum

pub type LoanDatum {
  commonData: CommonData,
  originAssetName: AssetName,
  borrowerAssetName: AssetName,
  lenderAssetName: AssetName,
  collateral: CollateralAsset,
  principalAmount: Int,
  principalDivider: Int,
  lendDate: Int,
  repaidInstallments: Int,
  doneRecasts: Int,
}

pub type RepaymentDatum {
  RepaymentDatumWithToken { action: ByteArray, data: Data, ownerAsset: Asset }
  RepaymentDatumWithHash {
    action: ByteArray,
    data: Data,
    ownerAuthHash: AuthorizationMethod,
  }
}

pub type DutchAuctionDatum {
  ownerAuthHash: AuthorizationMethod,
  ownerAddress: Address,
  currency: Asset,
  startingPrice: Int,
  loweringAmount: Int,
  loweringFrequency: Int,
  minPriceToCancel: Int,
  startDate: Int,
  //If present it means it's a ducth auction from a liquidated asset:
  //The lender must get max principal+interest
  //The borrower gets the difference if the earning from the auction are > what lender should get
  borrowerAddress: Option<Address>,
  //Used only if liquidatedBorrowerAddress is not None, it's how much the lender should get
  debtAmount: Int,
}
