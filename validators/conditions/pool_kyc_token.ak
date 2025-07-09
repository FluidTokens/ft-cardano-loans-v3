use aiken/builtin
use aiken/cbor.{serialise}
use aiken/collection/list
use aiken/crypto.{
  Blake2b_256, Hash, Signature, VerificationKey, VerificationKeyHash,
  blake2b_224, blake2b_256, verify_ed25519_signature,
}
use aiken/interval.{Finite, Interval, IntervalBound}
use cardano/address.{Address, Credential, Script}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, ValidityRange,
  Withdraw,
}
use fluidtokens/types/pool.{Borrow, PoolWithdrawRedeemer}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{get_inputs_from_smart_credential} as st_utils

pub type PermissionedDatum {
  whitelisted_oracles: List<VerificationKeyHash>,
}

pub type TokenData {
  // The users DID Identifier
  did: ByteArray,
  //The users public key
  user_key: VerificationKeyHash,
  //The Address of the pool input
  origin_output_reference: OutputReference,
  //Blake2b-256 hash of the cbor serialized borrow action
  borrow_action_hash: Hash<Blake2b_256, Data>,
  //A valid range
  validity_range: ValidityRange,
  //The public key of the oracle
  oracle_key: VerificationKey,
}

pub type ComplianceToken {
  token: TokenData,
  //A signature from the compliance oracle for serialized TokenData
  oracle_signature: Signature,
}

pub type KycTokenWithdrawRedeemer {
  poolWithdrawRedeemerIndex: Int,
  complianceForEachInput: List<ComplianceToken>,
}

validator kyc_token(
  poolPolicyId: ByteArray,
  poolSpendScriptHash: ByteArray,
  smartTokensSpendScriptHash: ByteArray,
) {
  withdraw(
    redeemer: KycTokenWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(scriptHash) = credential

    let poolWithdrawRedeemer =
      safe_list_at(self.redeemers, redeemer.poolWithdrawRedeemerIndex)
    expect poolWithdrawRedeemer.1st == Withdraw(Script(poolPolicyId))
    expect poolRedeemer: PoolWithdrawRedeemer = poolWithdrawRedeemer.2nd
    let poolInputsAndActions =
      list.zip(
        get_inputs_from_smart_credential(
          self.inputs,
          Script(poolSpendScriptHash),
          Script(poolPolicyId),
          smartTokensSpendScriptHash,
        ),
        poolRedeemer.actionsForEachInput,
      )

    let poolInputsAndActionsThatNeedThisCondition =
      list.filter(
        poolInputsAndActions,
        fn(inputAndAction) {
          expect InlineDatum(inputDatum) = inputAndAction.1st.output.datum
          when inputAndAction.2nd is {
            Borrow { .. } ->
              //First field of datum is permissionedConditionScriptHash
              (
                inputDatum
                  |> builtin.unconstr_fields
                  |> builtin.head_list
                  |> builtin.un_b_data
              ) == scriptHash
            _ -> False
          }
        },
      )

    //As we loop through the inputs we DO NOT need to ensure that the number of tokens is equal to the number of inputs
    list.indexed_foldr(
      poolInputsAndActionsThatNeedThisCondition,
      True,
      fn(index, inputAndAction, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        expect InlineDatum(inputDatum) = inputAndAction.1st.output.datum
        //Second field of datum is extraData
        let extraData =
          inputDatum
            |> builtin.unconstr_fields
            |> builtin.tail_list
            |> builtin.head_list
        let compliance = safe_list_at(redeemer.complianceForEachInput, index)

        expect
          compliance.token.origin_output_reference == inputAndAction.1st.output_reference
        expect Borrow { borrowerAddress, .. } = inputAndAction.2nd

        expect Interval {
          lower_bound: IntervalBound { bound_type: Finite(tx_from), .. },
          upper_bound: IntervalBound { bound_type: Finite(tx_to), .. },
        } = self.validity_range

        expect Interval {
          lower_bound: IntervalBound { bound_type: Finite(token_from), .. },
          upper_bound: IntervalBound { bound_type: Finite(token_to), .. },
        } = compliance.token.validity_range

        expect PermissionedDatum { whitelisted_oracles } = extraData
        let oracle_key_hash = blake2b_224(compliance.token.oracle_key)
        //The oracle public key is one of those listed in the approved oracles
        expect Some(..) =
          list.find(whitelisted_oracles, fn(o) { o == oracle_key_hash })
        and {
          address.VerificationKey(compliance.token.user_key) == borrowerAddress.payment_credential,
          //The hash of the Borrow action must be the one in the compliance token
          blake2b_256(serialise(inputAndAction.2nd)) == compliance.token.borrow_action_hash,
          //The valid range of the token entirely contains the valid range of the transaction
          token_from < tx_from,
          token_to > tx_to,
          //The signature is valid
          verify_ed25519_signature(
            compliance.token.oracle_key,
            serialise(compliance.token),
            compliance.oracle_signature,
          ),
        }
      },
    )
  }

  else(_) {
    fail
  }
}
