use aiken/hash.{Blake2b_224, Hash}
use aiken/transaction/credential.{Address, VerificationKey}
use aiken/transaction/value.{AssetName, PolicyId, Value}
use types/general.{Asset, CollateralAsset}

pub type OracleLTVPoolDatum {
  lenderAddress: Address,
  poolAsset: Asset,
  //This pool can cover multiple collections/token, but only one of them can be chosen for each loan (ie. no mixed bundle loans)
  collateralOptions: List<CollateralAsset>,
  //LTV for each collateral option (borrower can ask more using a multiple)
  principalLTV: List<Int>,
  principalLTVDivider: List<Int>,
  //Per mille of the loan to repay to lender
  interestRate: Int,
  loanDuration: Int,
  totalInstallments: Int,
}

pub type ActiveDatum {
  borrowerNFT: AssetName,
  loan: Asset,
  loanAmnt: Int,
  interest: Asset,
  interestAmnt: Int,
  collateral: Value,
  loanDuration: Int,
  lenderNFT: AssetName,
  lendDate: Int,
  totalInstallments: Int,
  installmentsRepaid: Int,
}
