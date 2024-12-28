use aiken/collection/list
use cardano/address.{Script}
use cardano/transaction.{OutputReference, Transaction}
use fluidtokens/authorizer
use fluidtokens/utils.{get_config, safe_list_at}

validator general_spend(
  withdrawScriptHash: ByteArray,
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  spend(
    datumOpt: Option<Data>,
    _redeemer: Data,
    _input: OutputReference,
    self: Transaction,
  ) {
    if datumOpt == None {
      authorizer.authorize_via_credential(
        get_config(
          safe_list_at(self.reference_inputs, 0),
          configNFTPolicyId,
          configNFTAssetName,
        ).adminCredential,
        self.withdrawals,
        self.extra_signatories,
      )
    } else {
      list.any(
        self.withdrawals,
        fn(withdrawal) {
          when withdrawal is {
            Pair(Script(scriptHash), _amnt) -> scriptHash == withdrawScriptHash
            _ -> False
          }
        },
      )
    }
  }

  else(_) {
    fail
  }
}
