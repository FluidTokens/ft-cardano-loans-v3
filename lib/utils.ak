use aiken/builtin
use aiken/collection/dict.{to_pairs}
use aiken/collection/list.{length}
use aiken/collection/pairs
use aiken/crypto.{VerificationKeyHash}
use aiken/interval.{Finite}
use aiken/math/rational.{Rational}
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Inline, Script, VerificationKey}
use cardano/assets.{
  AssetName, PolicyId, Value, quantity_of, reduce, to_dict, tokens,
}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Redeemer, ScriptPurpose,
  Transaction, Withdraw,
}
use types/datum.{ConfigDatum}
use types/general.{
  Asset, Authorization, CardanoMintScript, CardanoSignature, CardanoSpendScript,
  CardanoWithdrawScript, CollateralAsset,
}
use types/redeemer.{
  Aggregated, Dedicated, OraclePriceFeed, OracleRedeemer, Pooled,
}

pub fn token_name_has_header(tokenName: ByteArray, header: Int) -> Bool {
  bytearray.at(tokenName, 0) == header
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

pub fn is_output_to_sc_or_cip_113(output: Output, scHash: ByteArray) {
  let is_output_to_sc = is_output_to_sc(output, scHash)
  let is_stake =
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

  or {
    is_output_to_sc,
    is_stake,
  }
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

pub fn is_script_output(output: Output) -> Bool {
  when output.address.payment_credential is {
    Script(_) -> True
    _ -> False
  }
}

pub fn only_one_sc_used(inputs: List<Input>, scHash: ByteArray) {
  let inputsWithDatum =
    list.filter(inputs, fn(input) { is_script_output(input.output) })
  length(get_inputs_from_sc(inputs, scHash)) == length(inputsWithDatum)
}

pub fn must_be_signed_by(transaction: Transaction, address: Address) {
  expect VerificationKey(hash) = address.payment_credential
  list.has(transaction.extra_signatories, hash)
}

pub fn address_in_signatures(
  extra_signatories: List<VerificationKeyHash>,
  address: Address,
) {
  expect VerificationKey(hash) = address.payment_credential
  list.has(extra_signatories, hash)
}

pub fn get_own_hash(output_reference: OutputReference, txInputs: List<Input>) {
  expect Some(input) =
    list.find(txInputs, fn(x) { x.output_reference == output_reference })

  expect Script(hash) = input.output.address.payment_credential
  hash
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

pub fn value_to_pairs(value: Value) -> Pairs<PolicyId, Pairs<AssetName, Int>> {
  //This gives us Dict<PolicyId, Dict<ByteArray, Int>>
  let valueAsDict = to_dict(value)
  //This gives us Dict<PolicyId, Pairs<ByteArray, Int>>
  let dictOfPairs =
    dict.map(valueAsDict, fn(_k, innerDict) { dict.to_pairs(innerDict) })
  dict.to_pairs(dictOfPairs)
}

//pub fn value_to_pairs(value: Data) -> Pairs<PolicyId, Pairs<AssetName, Int>> {
//  let vAsData: Data = value
//  expect vAsPairList: List<Pair<PolicyId, Pairs<AssetName, Int>>> =
//    builtin.un_map_data(vAsData)
//  expect vAsPairs: Pairs<PolicyId, Pairs<AssetName, Int>> = vAsPairList
//  vAsPairs
//}

pub fn is_feed_token_correct(
  expectedCollateral: CollateralAsset,
  feedToken: Asset,
) {
  when expectedCollateral.maybeAssetName is {
    Some(assetName) -> and {
        feedToken.policyId == expectedCollateral.policyId,
        feedToken.assetName == assetName,
      }
    None -> feedToken.policyId == expectedCollateral.policyId
  }
}

pub fn retrieve_oracle_data(
  oracleInput: Input,
  redeemers: Pairs<ScriptPurpose, Redeemer>,
  transaction_valid_to: Int,
  expectedCollateral: CollateralAsset,
) -> Option<OraclePriceFeed> {
  expect Some(loan_oracle_redeemer) =
    pairs.get_first(
      redeemers,
      Withdraw(oracleInput.output.address.payment_credential),
    )
  expect loan_tokens_price: OracleRedeemer = loan_oracle_redeemer

  let commonFeedData =
    when loan_tokens_price.data is {
      Pooled { common, .. } -> common
      Aggregated { common, .. } -> common
      Dedicated { common, .. } -> common
    }
  if and {
    commonFeedData.valid_to - commonFeedData.valid_from <= 3600000,
    commonFeedData.valid_to >= transaction_valid_to,
    is_feed_token_correct(expectedCollateral, commonFeedData.token),
  } {
    Some(loan_tokens_price.data)
  } else {
    trace @"oracle is expired, has wrong token or wrong interval"
    None
  }
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

pub fn validate_oracle_ref_input(
  oracleInputValue: Value,
  chosenCollateral: CollateralAsset,
) {
  expect Some(oracleToken) = chosenCollateral.maybeOracleTokenAsset
  quantity_of(oracleInputValue, oracleToken.policyId, oracleToken.assetName) > 0
}
