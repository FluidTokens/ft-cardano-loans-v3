use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Credential}
use cardano/assets.{AssetName, PolicyId, Value}
use cardano/transaction.{Input}

pub type Asset {
  policyId: PolicyId,
  assetName: AssetName,
}

pub type CollateralAsset {
  policyId: PolicyId,
  maybeAssetName: Option<AssetName>,
  //Put the dummy value Asset{"NONE","NONE"} if you are  NOT using an oracle token
  oracleTokenAsset: Asset,
}

pub type AuthorizationMethod {
  CardanoSignature { hash: ByteArray }
  CardanoSpendScript { hash: ByteArray }
  CardanoWithdrawScript { hash: ByteArray }
  CardanoMintScript { hash: ByteArray }
}

pub type Authorization {
  CardanoSignatureAuth {
    hash: ByteArray,
    extra_signatories: List<VerificationKeyHash>,
  }
  CardanoSpendScriptAuth { hash: ByteArray, transaction_inputs: List<Input> }
  CardanoWithdrawScriptAuth {
    hash: ByteArray,
    withdrawals: Pairs<Credential, Int>,
  }
  CardanoMintScriptAuth { hash: ByteArray, transaction_mint: Value }
}

pub type RepaymentMode {
  //Amortization. Express number of possible recasts: 0 means no recasting, if you want "unlimited" just put a very big int
  InterestOnRemainingPrincipal { max_possible_recasts: Int }
  //Installment amount = Principal+Interest/Installments
  PrincipalAndInterestOnInstallments
  //Perpetual loans don't have a deadline, the borrower can repay whenever he wants
  //The APY increases over time linearly and if installments are > 1 and they are not paid in time
  //the borrower can be liquidated
  //At each installment the borrower has to pay only the interest since last installment
  //When the borrower wants to close the loan, he has to pay the principal + interest since last installment
  //Liquidation for too low ltv is always possible if enabled
  //initialGracePeriod allows not to repay for a certain period after the loan starts but the interest rate keeps increasing!
  //So the first installment requires you to pay that too
  //Recasting is permitted when enabled
  //APY = mx + c = apyIncreaseLinearCoefficient/1000000 * x + interestRate/10000 (the variable called as such)
  //Hourly interest rate = c / 8760
  //Normal installment amount = hourly interest rate * installmentPeriod
  PerpetualLoan { apyIncreaseLinearCoefficient: Int, max_possible_recasts: Int }
}

pub type LiquidationMode {
  NoLiquidationFullCollateralClaim
  NoLiquidationDutchAuctionClaim
  Liquidation {
    lTV: Int,
    lTVDivider: Int,
    //If true, 
    //If negative, borrower loses all the collateral when liquidation happens
    //If >= 0, when claiming the collateral the lender must pay to the borrower the difference
    //If > 0, this represents the per mille of the debt that must be given to the lender as penalty for being liquidated
    partialLiquidationPenaltyPerMille: Int,
  }
}
