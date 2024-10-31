use cardano/assets.{PolicyId, flatten, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Redeemer, Transaction,
}
use types/general.{Asset, CollateralAsset}

//Contains all SC params
validator config(gov_nft: Asset) {
  mint(redeemer: Data, policy_id: PolicyId, self: Transaction) {
    todo
  }

  spend(
    datumOpt: Option<Data>,
    redeemer: Data,
    input: OutputReference,
    self: Transaction,
  ) {
    todo
  }

  else(_) {
    fail
  }
}
