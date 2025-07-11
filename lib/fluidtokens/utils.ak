use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto
use aiken/interval.{Finite}
use aiken/primitive/bytearray
use cardano/address.{Address, Script}
use cardano/assets.{AssetName, PolicyId, Value, quantity_of, reduce, tokens}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
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

pub fn get_config_as_data_list(
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
  builtin.unconstr_fields(outputDatum)
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

pub fn is_output_to_spend_validator(
  output: Output,
  spendValidatorScriptHash: ByteArray,
) -> Bool {
  when output.address.payment_credential is {
    Script(hash) -> hash == spendValidatorScriptHash
    _ -> False
  }
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

pub fn efficient_quantity_of(
  input: Input,
  policyId: PolicyId,
  policyIdIndex: Int,
  assetName: AssetName,
  assetNameIndex: Int,
) -> Int {
  let value_as_list_data =
    builtin.un_map_data(
      safe_list_at(
        builtin.unconstr_fields(safe_list_at(builtin.unconstr_fields(input), 1)),
        1,
      ),
    )
  let policyIdPair = safe_list_at(value_as_list_data, policyIdIndex)

  let assetNamePair =
    safe_list_at(
      builtin.un_map_data(builtin.snd_pair(policyIdPair)),
      assetNameIndex,
    )

  expect
    builtin.equals_data(builtin.fst_pair(policyIdPair), policyId) && builtin.equals_data(
      builtin.fst_pair(assetNamePair),
      assetName,
    )
  builtin.un_i_data(builtin.snd_pair(assetNamePair))
}
