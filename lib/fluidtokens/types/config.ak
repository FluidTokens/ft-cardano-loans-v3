use cardano/address.{Credential}

pub type ConfigDatum {
  //When the borrower borrows, he also has to create the lender bond with min_ada inside.
  //Therefore he must be compensated directly from the lender pool.
  borrowerPoolExtraCompensation: Int,
  smartTokensSpendScriptHash: ByteArray,
  adminCredential: Credential,
  poolPolicyId: ByteArray,
  requestPolicyId: ByteArray,
  borrowerBondPolicyId: ByteArray,
  lenderBondPolicyId: ByteArray,
  loanPolicyId: ByteArray,
  repaymentPolicyId: ByteArray,
  poolSpendScriptHash: ByteArray,
  requestSpendScriptHash: ByteArray,
  loanSpendScriptHash: ByteArray,
  repaymentSpendScriptHash: ByteArray,
  dutchAuctionSpendScriptHash: ByteArray,
  dutchAuctionWithdrawScriptHash: ByteArray,
  dutchAuctionStartingIncreasePerMille: Int,
  dutchAuctionLoweringAmount: Int,
  dutchAuctionLoweringFrequency: Int,
  dutchAuctionMinPriceToCancel: Int,
}
