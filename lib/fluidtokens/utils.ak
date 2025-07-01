use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto.{VerificationKeyHash}
use aiken/interval.{Finite}
use aiken/primitive/bytearray
use cardano/address.{Address, Inline, Script, VerificationKey}
use cardano/assets.{AssetName, PolicyId, Value, quantity_of, reduce, tokens}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use fluidtokens/types/config.{ConfigDatum}
use fluidtokens/types/general.{Asset}
use fluidtokens/types/oracle.{
  CharlieTokenSpecs, GenericData, OrcfaxTokenSpecs, PriceData,
}

pub fn indexed_filter(list: List<a>, predicate: fn(Int, a) -> Bool) -> List<a> {
  list.indexed_foldr(
    list,
    [],
    fn(index, elem, acc) {
      if predicate(index, elem) {
        list.push(acc, elem)
      } else {
        acc
      }
    },
  )
}

pub fn hash_output_ref(outputRef: OutputReference) -> ByteArray {
  outputRef |> builtin.serialise_data |> crypto.blake2b_224
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

pub fn is_nft_in_input(
  policyId: PolicyId,
  assetName: AssetName,
  inputWithToken: Input,
) {
  quantity_of(inputWithToken.output.value, policyId, assetName) == 1
}

pub fn is_nft_in_output(
  policyId: PolicyId,
  assetName: AssetName,
  outputWithToken: Output,
) {
  quantity_of(outputWithToken.value, policyId, assetName) == 1
}

pub fn validity_range_within_an_hour(tx: Transaction) {
  expect Finite(start) = tx.validity_range.lower_bound.bound_type
  expect Finite(end) = tx.validity_range.upper_bound.bound_type

  // 1 hour in millis
  end - start <= 3600000
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

pub fn is_output_to_spend_validator(
  output: Output,
  spendValidatorScriptHash: ByteArray,
) -> Bool {
  when output.address.payment_credential is {
    Script(hash) -> hash == spendValidatorScriptHash
    _ -> False
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

/// Returns the number of different asset names with the policyId
pub fn asset_names_number_of_policy_id(value: Value, policyId: PolicyId) {
  dict.foldl(tokens(value, policyId), 0, fn(_k, _v, result) { 1 + result })
}

pub fn safe_list_at(self: List<a>, index: Int) -> a {
  expect index >= 0
  do_list_at(self, index)
}

fn do_list_at(self: List<a>, index: Int) -> a {
  if index == 0 {
    builtin.head_list(self)
  } else {
    do_list_at(builtin.tail_list(self), index - 1)
  }
}

pub fn safe_expect(maybeElem: Option<a>) -> a {
  expect Some(elem) = maybeElem
  elem
}

//-------------------------- CHARLIE 3 UTILS

pub fn get_oracle_info(price_data: PriceData) -> (Int, Int, Int) {
  when price_data is {
    GenericData { price_map } ->
      when price_map is {
        [Pair(0, price), Pair(1, timestamp), Pair(2, expiry)] ->
          (price, timestamp, expiry)
        _ -> fail @"Invalid price, timestamp or expiry"
      }
    _ -> fail @"Invalid PriceData variant"
  }
}

pub fn get_oracle_config(
  oracle_specs: CharlieTokenSpecs,
  feedToken: Asset,
) -> (PolicyId, Int) {
  expect Some(token_pairs) = pairs.get_first(oracle_specs, feedToken.policyId)
  expect Some(result) = pairs.get_first(token_pairs, feedToken.assetName)
  result
}

//It requires that the keys are not duplicated
pub fn pairs_ordering(
  pair1: Pair<ByteArray, Int>,
  pair2: Pair<ByteArray, Int>,
) -> Ordering {
  bytearray.compare(pair1.1st, pair2.1st)
}

pub fn get_oracle_orcfax_config(
  oracle_specs: OrcfaxTokenSpecs,
  feedToken: Asset,
) -> (PolicyId, Int, ByteArray) {
  expect Some(token_pairs) = pairs.get_first(oracle_specs, feedToken.policyId)
  expect Some(result) = pairs.get_first(token_pairs, feedToken.assetName)
  result
}
