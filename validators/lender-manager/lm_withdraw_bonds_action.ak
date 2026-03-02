use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/lender_manager.{LenderManagerDatum} as lm

validator actionValidator(lenderManagerSpendScriptHash: ByteArray) {
  withdraw(_redeemer: Data, _credential: Credential, self: Transaction) {
    //Lender bonds always reside in lender_manager.ak, so we don't need to consider CIP113 utxos
    let lmInputs =
      list.filter(
        self.inputs,
        fn(input) {
          input.output.address.payment_credential == Script(
            lenderManagerSpendScriptHash,
          )
        },
      )
    list.all(
      lmInputs,
      fn(input: Input) -> Bool {
        expect InlineDatum(inputDatum) = input.output.datum
        expect LenderManagerDatum { lenderAuth, .. } = inputDatum
        authorize_action(
          create_auth(
            lenderAuth,
            self.inputs,
            self.withdrawals,
            self.extra_signatories,
            self.mint,
          ),
        )
      },
    )
  }

  else(_) {
    fail
  }
}
