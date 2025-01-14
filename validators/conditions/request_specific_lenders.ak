use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/transaction.{InlineDatum, Input, Output, Transaction, Withdraw}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/general.{AuthorizationMethod}
use fluidtokens/types/request.{Lend, RequestDatum, RequestWithdrawRedeemer}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{get_inputs_from_smart_credential} as st_utils

pub type PermissionedDatum {
  whitelisted_auths: List<AuthorizationMethod>,
}

pub type WithdrawRedeemer {
  requestWithdrawRedeemerIndex: Int,
  authorizationMethodIndex: List<Int>,
}

validator kyc_token(
  requestPolicyId: ByteArray,
  requestSpendScriptHash: ByteArray,
) {
  withdraw(
    redeemer: WithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(scriptHash) = credential

    let requestWithdrawRedeemer =
      safe_list_at(self.redeemers, redeemer.requestWithdrawRedeemerIndex)
    expect requestWithdrawRedeemer.1st == Withdraw(Script(requestPolicyId))
    expect requestRedeemer: RequestWithdrawRedeemer =
      requestWithdrawRedeemer.2nd
    let requestInputsAndActions =
      list.zip(
        get_inputs_from_smart_credential(
          self.inputs,
          Script(requestSpendScriptHash),
          credential,
        ),
        requestRedeemer.actionsForEachInput,
      )

    let requestInputsAndActionsThatNeedThisCondition =
      list.filter(
        requestInputsAndActions,
        fn(inputAndAction) {
          expect InlineDatum(inputDatum) = inputAndAction.1st.output.datum
          expect datum: RequestDatum = inputDatum
          when inputAndAction.2nd is {
            Lend { .. } -> datum.permissionedConditionScriptHash == scriptHash
            _ -> False
          }
        },
      )

    //As we loop through the inputs we DO NOT need to ensure that the number of tokens is equal to the number of inputs
    list.indexed_foldr(
      requestInputsAndActionsThatNeedThisCondition,
      True,
      fn(index, inputAndAction, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        expect InlineDatum(inputDatum) = inputAndAction.1st.output.datum
        expect datum: RequestDatum = inputDatum
        expect permissionedDatum: PermissionedDatum = datum.extraData

        let authorizationMethod =
          safe_list_at(permissionedDatum.whitelisted_auths, index)

        authorize_action(
          create_auth(
            authorizationMethod,
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
