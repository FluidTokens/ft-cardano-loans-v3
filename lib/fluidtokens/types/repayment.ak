use cardano/transaction.{OutputReference}
use fluidtokens/types/general.{Asset, AuthorizationMethod}

pub type RepaymentDatum {
  RepaymentDatumWithToken {
    inputOutputReference: OutputReference,
    action: ByteArray,
    data: Data,
    ownerAsset: Asset,
  }
  RepaymentDatumWithHash {
    inputOutputReference: OutputReference,
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
  WithdrawWithToken { tokenOutputIndex: Int }
  WithdrawWithHash
}

pub type RepaymentWithdrawRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<(RepaymentAction, ByteArray)>,
}
