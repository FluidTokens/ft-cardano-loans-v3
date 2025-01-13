use cardano/transaction.{OutputReference}
use fluidtokens/types/general.{Asset, AuthorizationMethod}

pub type RepaymentDatum {
  RepaymentDatumWithToken { action: ByteArray, data: Data, ownerAsset: Asset }
  RepaymentDatumWithHash {
    action: ByteArray,
    data: Data,
    ownerAuth: AuthorizationMethod,
  }
}

pub type RepaymentMintRedeemer {
  configRefInputIndex: Int,
  inputRef: OutputReference,
  loanWithdrawRedeemerIndex: Int,
}

pub type RepaymentAction {
  WithdrawWithToken { tokenInputIndex: Int }
  WithdrawWithHash
}

pub type RepaymentWithdrawRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<(RepaymentAction, ByteArray)>,
}
