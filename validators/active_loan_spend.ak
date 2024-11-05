use aiken/collection/list
use cardano/address.{Script}
use cardano/transaction.{OutputReference, Transaction}
use types/datum.{PoolDatum}
use utils.{address_in_signatures, get_config, safe_list_at}

validator repayment(
  activeLoanWithdrawScriptHash: ByteArray,
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  spend(
    datumOpt: Option<PoolDatum>,
    _redeemer: Data,
    _input: OutputReference,
    self: Transaction,
  ) {
    if datumOpt == None {
      address_in_signatures(
        self.extra_signatories,
        get_config(
          safe_list_at(self.reference_inputs, 0),
          configNFTPolicyId,
          configNFTAssetName,
        ).adminAddress,
      )
    } else {
      list.any(
        self.withdrawals,
        fn(withdrawal) {
          when withdrawal is {
            Pair(Script(scriptHash), _amnt) ->
              scriptHash == activeLoanWithdrawScriptHash
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
