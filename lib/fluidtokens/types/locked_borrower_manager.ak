use cardano/transaction.{OutputReference}
use fluidtokens/types/general.{AuthorizationMethod}

pub type LockedBorrowerManagerDatum {
  originRef: OutputReference,
  //Who can spend the borrower bond
  borrowerAuth: AuthorizationMethod,
}

pub type LockedBorrowerManagerWithdrawRedeemer {
  configRefInputIndex: Int,
  borrowerBondAssetNames: List<ByteArray>,
}
