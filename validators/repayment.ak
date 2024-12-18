//All money to parties are sent here so they can withdraw them
use aiken/collection/list.{length}
use cardano/address.{Credential, Script}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use types/datum.{RepaymentDatum,
  RepaymentDatumWithHash, RepaymentDatumWithToken}
use types/general.{Asset}
use types/redeemer.{
  RepaymentWithdrawRedeemer, WithdrawWithHash, WithdrawWithToken,
}
use utils.{
  authorize_action, get_inputs_from_sc_or_delegated_to_sc, is_nft_spent,
  safe_list_at,
}

validator repayment {
  withdraw(
    redeemer: RepaymentWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(ownScriptHash) = credential
    let scInputs =
      get_inputs_from_sc_or_delegated_to_sc(self.inputs, ownScriptHash)
    //Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
    expect length(scInputs) == length(redeemer.actionsForEachInput)

    list.indexed_foldr(
      scInputs,
      True,
      fn(index, inputAndCIP113Control, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        let input = inputAndCIP113Control.1st
        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: RepaymentDatum = inputDatum
        let redeemerAction = safe_list_at(redeemer.actionsForEachInput, index)

        when redeemerAction is {
          WithdrawWithToken(tokenInputIndex) -> {
            expect RepaymentDatumWithToken(_action, _data, ownerAsset) = datum
            expect Some(tokenInput) = list.at(self.inputs, tokenInputIndex)
            is_nft_spent(ownerAsset.policyId, ownerAsset.assetName, tokenInput)
          }
          WithdrawWithHash(auth) -> {
            expect RepaymentDatumWithHash(_action, _data, ownerAuthHash) = datum
            and {
              ownerAuthHash == auth.hash,
              authorize_action(
                auth,
                self.inputs,
                self.withdrawals,
                self.extra_signatories,
                self.mint,
              ),
            }
          }
        }
      },
    )
  }

  else(_) {
    fail
  }
}
