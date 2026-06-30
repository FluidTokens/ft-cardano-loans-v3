use aiken/builtin
use aiken/collection/list.{length}
use cardano/address.{Address, Credential, Script}
use cardano/assets.{flatten, quantity_of}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/locked_borrower_manager.{
  LockedBorrowerManagerDatum, LockedBorrowerManagerWithdrawRedeemer,
}
use fluidtokens/utils.{safe_list_at}

validator lockedBorrowerManager(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  withdraw(
    redeemer: LockedBorrowerManagerWithdrawRedeemer,
    _credential: Credential,
    self: Transaction,
  ) {
    let config =
      utils.get_config_as_data_list(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let borrowerBondPolicyId = builtin.un_b_data(utils.safe_list_at(config, 4))
    let lockedBorrowerManagerSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 28))

    let lockedBorrowerManagerInputs =
      list.filter(
        self.inputs,
        fn(input) {
          input.output.address.payment_credential == Script(
            lockedBorrowerManagerSpendScriptHash,
          )
        },
      )

    let lockedBorrowerManagerOutputs =
      list.filter(
        self.outputs,
        fn(output) {
          output.address.payment_credential == Script(
            lockedBorrowerManagerSpendScriptHash,
          )
        },
      )

    utils.indexed_all(
      lockedBorrowerManagerInputs,
      fn(index, input) {
        expect InlineDatum(inputDatum) = input.output.datum
        expect LockedBorrowerManagerDatum { borrowerAuth, .. } = inputDatum

        let borrowerBondAssetName =
          safe_list_at(redeemer.borrowerBondAssetNames, index)

        let borrowerBondOutput =
          safe_list_at(lockedBorrowerManagerOutputs, index)

        and {
          //Input must only have a bond and lovelace
          length(flatten(input.output.value)) == 2,
          //Input must have the borrower bond
          quantity_of(
            input.output.value,
            borrowerBondPolicyId,
            borrowerBondAssetName,
          ) == 1,
          //Authorize the bond owner to execute this action
          authorize_action(
            create_auth(
              borrowerAuth,
              self.inputs,
              self.withdrawals,
              self.extra_signatories,
              self.mint,
            ),
          ),
          //Either the bond is burnt or it goes back here with no changes
          or {
            quantity_of(self.mint, borrowerBondPolicyId, borrowerBondAssetName) == -1,
            builtin.equals_data(input.output, borrowerBondOutput),
          },
        }
      },
    )
  }

  else(_) {
    fail
  }
}
