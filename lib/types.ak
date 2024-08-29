use aiken/hash.{Blake2b_224, Hash}
use aiken/transaction/credential.{Address, VerificationKey}
use aiken/transaction/value.{AssetName, PolicyId, Value}

pub type Asset {
  policyId: PolicyId,
  assetName: AssetName,
}

pub type CollectionAmount {
  policyId: PolicyId,
  amount: Int,
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

pub type RepaymentDatum {
  lenderNFT: AssetName,
  //How many installments this repayment contains?
  installmentsContained: Int,
  //Repaid loan installments included these
  installmentsPaidSoFar: Int,
  //Does it contain the very last repayment of the loan?
  isFinalRepayment: Bool,
}

pub type BondsGraveyardDatum {
  ownerAddress: Address,
}

pub type VerificationKeyHash =
  Hash<Blake2b_224, VerificationKey>
