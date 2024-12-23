use aiken/builtin
use aiken/collection/dict.{to_pairs}
use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto.{VerificationKeyHash}
use aiken/interval.{Finite}
use aiken/math/rational.{Rational}
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Inline, Script, VerificationKey}
use cardano/assets.{AssetName, PolicyId, Value, quantity_of, reduce, tokens}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use fluidtokens/types/datum.{ConfigDatum}
use fluidtokens/types/general.{
  Authorization, CardanoMintScript, CardanoSignature, CardanoSpendScript,
  CardanoWithdrawScript,
}

pub fn hash_output_ref(outputRef: OutputReference) -> ByteArray {
  crypto.sha2_256(
    bytearray.push(outputRef.transaction_id, outputRef.output_index),
  )
}

pub fn get_config(
  configRefInput: Input,
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  expect
    quantity_of(
      configRefInput.output.value,
      configNFTPolicyId,
      configNFTAssetName,
    ) > 0
  expect InlineDatum(outputDatum) = configRefInput.output.datum
  expect parsedDatum: ConfigDatum = outputDatum
  parsedDatum
}

pub fn value_without_policy_id_as_list(value: Value, policyIdToRemove: PolicyId) {
  reduce(
    value,
    [],
    fn(policyId, assetName, quantity, acc) {
      if policyId != policyIdToRemove {
        list.push(acc, (policyId, assetName, quantity))
      } else {
        acc
      }
    },
  )
}

pub fn is_nft_burnt(policyId: PolicyId, assetName: AssetName, mints: Value) {
  quantity_of(mints, policyId, assetName) == -1
}

pub fn is_nft_spent(
  policyId: PolicyId,
  assetName: AssetName,
  inputWithToken: Input,
) {
  quantity_of(inputWithToken.output.value, policyId, assetName) == 1
}

pub fn validity_range_within_an_hour(tx: Transaction) {
  expect Finite(start) = tx.validity_range.lower_bound.bound_type
  expect Finite(end) = tx.validity_range.upper_bound.bound_type

  // 1 hour in millis
  end - start <= 3600000
}

pub fn is_output_to_sc(output: Output, scHash: ByteArray) -> Bool {
  when output.address.payment_credential is {
    Script(hash) -> hash == scHash
    _ -> False
  }
}

pub fn get_outputs_to_sc(
  outputs: List<Output>,
  scHash: ByteArray,
) -> List<Output> {
  list.filter(outputs, fn(output) { is_output_to_sc(output, scHash) })
}

pub fn get_inputs_from_sc(inputs: List<Input>, scHash: ByteArray) -> List<Input> {
  list.filter(inputs, fn(input) { is_output_to_sc(input.output, scHash) })
}

pub fn is_output_delegated_to_sc(output: Output, scHash: ByteArray) {
  when output.address.stake_credential is {
    Some(stake_cred) -> {
      expect Inline(a) = stake_cred
      when a is {
        VerificationKey(hash) -> hash == scHash
        Script(hash) -> hash == scHash
      }
    }
    None -> False
  }
}

//Returns a list of couples (INPUT, IS_CIP_113), removing all the other inputs
pub fn get_inputs_from_sc_or_delegated_to_sc(
  inputs: List<Input>,
  scHash: ByteArray,
) -> List<(Input, Bool)> {
  list.foldr(
    inputs,
    [],
    fn(input, result) {
      let output = input.output
      if is_output_to_sc(output, scHash) {
        list.push(result, (input, False))
      } else {
        if is_output_delegated_to_sc(output, scHash) {
          list.push(result, (input, True))
        } else {
          result
        }
      }
    },
  )
}

pub fn get_outputs_to_sc_or_delegated_to_sc(
  outputs: List<Output>,
  scHash: ByteArray,
  isCIP113: Bool,
) {
  if isCIP113 {
    list.filter(outputs, fn(output) { is_output_to_sc(output, scHash) })
  } else {
    list.filter(
      outputs,
      fn(output) { is_output_delegated_to_sc(output, scHash) },
    )
  }
}

pub fn address_in_signatures(
  extra_signatories: List<VerificationKeyHash>,
  address: Address,
) {
  expect VerificationKey(hash) = address.payment_credential
  list.has(extra_signatories, hash)
}

/// Returns the quantity of all tokens with the policyId
pub fn quantity_of_policy_id(value: Value, policyId: PolicyId) {
  dict.foldl(tokens(value, policyId), 0, fn(_k, v, result) { v + result })
}

pub fn safe_list_at(list: List<a>, index: Int) {
  safe_expect(list.at(list, index))
}

pub fn safe_expect(maybeElem: Option<a>) {
  expect Some(elem) = maybeElem
  elem
}

// Calculate the tokenB (the pool asset such as ADA or stablecoin) required to purchase buy_amount of tokenA
pub fn token_b_needed_to_purchase_token_a(
  buy_amount: Rational,
  token_a_amount: Int,
  token_b_amount: Int,
) -> Int {
  let buy_amount_int = buy_amount |> rational.truncate()

  let nominator = buy_amount_int * 1000 * token_b_amount
  let denominator = ( token_a_amount - buy_amount_int ) * 997
  let token_b_required = nominator / denominator
  token_b_required
}

pub fn authorize_action(
  auth: Authorization,
  transaction_inputs: List<Input>,
  withdrawals: Pairs<Credential, Int>,
  extra_signatories: List<VerificationKeyHash>,
  transaction_mint: Value,
) -> Bool {
  when auth.method is {
    // If the authorization method is PubKey, validate using the provided signature.
    CardanoSignature -> list.has(extra_signatories, auth.hash)
    // If the authorization method is SpendScript, ensure the Utxo is present in the transaction inputs.
    CardanoSpendScript -> {
      let auth_cred = Script(auth.hash)
      list.any(
        transaction_inputs,
        fn(input) {
          let Input { output, .. } = input
          let Output { address: out_address, .. } = output
          let Address { payment_credential: out_payment_credential, .. } =
            out_address
          out_payment_credential == auth_cred
        },
      )
    }
    // If the authorization method is WithdrawScript, validate the presence of a withdrawal in the transaction.
    CardanoWithdrawScript -> {
      let credential = Script(auth.hash)
      pairs.has_key(withdrawals, credential)
    }
    // If the authorization method is MintScript, ensure the minted tokens meet the policy ID requirements and have a non-zero quantity.
    CardanoMintScript -> {
      let fst_token_quantity =
        transaction_mint
          |> tokens(auth.hash)
          |> to_pairs
          |> builtin.head_list
          |> builtin.snd_pair
      fst_token_quantity != 0
    }
  }
}
