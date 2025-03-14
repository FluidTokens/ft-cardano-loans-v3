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
  CharlieTokenSpecs, GenericData, OracleDatum, PriceData,
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

pub fn safe_list_at(list: List<a>, index: Int) {
  safe_expect(list.at(list, index))
}

pub fn safe_expect(maybeElem: Option<a>) {
  expect Some(elem) = maybeElem
  elem
}

//-------------------------- CHARLIE 3 UTILS

/// Retrieves the price from the PriceData
///
/// @param price_data - The PriceData to extract the price from
/// @return The price as an Int
pub fn get_price(price_data: PriceData) -> Int {
  when price_data is {
    GenericData { price_map } ->
      when pairs.get_first(price_map, 0) is {
        Some(price) -> price
        None -> fail @"Price not found"
      }
    _ -> fail @"Invalid PriceData variant"
  }
}

/// Retrieves the timestamp from the PriceData
///
/// @param price_data - The PriceData to extract the timestamp from
/// @return The timestamp as an Int
pub fn get_timestamp(price_data: PriceData) -> Int {
  when price_data is {
    GenericData { price_map } ->
      when pairs.get_first(price_map, 1) is {
        Some(timestamp) -> timestamp
        None -> fail @"Timestamp not found"
      }
    _ -> fail @"Invalid PriceData variant"
  }
}

/// Retrieves the expiry from the PriceData
///
/// @param price_data - The PriceData to extract the expiry from
/// @return The expiry as an Int
pub fn get_expiry(price_data: PriceData) -> Int {
  when price_data is {
    GenericData { price_map } ->
      when pairs.get_first(price_map, 2) is {
        Some(expiry) -> expiry
        None -> fail @"Expiry not found"
      }
    _ -> fail @"Invalid PriceData variant"
  }
}

/// Checks if the oracle data is valid (not expired)
///
/// @param oracle_datum - The OracleDatum to check
/// @param current_time - The current time to compare against
/// @return True if the oracle is valid, False otherwise
pub fn is_oracle_valid(oracle_datum: OracleDatum, current_time: Int) -> Bool {
  current_time <= get_expiry(oracle_datum.price_data)
}

/// Retrieves the price from the OracleDatum
///
/// @param oracle_datum - The OracleDatum to extract the price from
/// @return The price as an Int
pub fn get_oracle_price(oracle_datum: OracleDatum) -> Int {
  get_price(oracle_datum.price_data)
}

/// Retrieves the timestamp from the OracleDatum
///
/// @param oracle_datum - The OracleDatum to extract the timestamp from
/// @return The timestamp as an Int
pub fn get_oracle_timestamp(oracle_datum: OracleDatum) -> Int {
  get_timestamp(oracle_datum.price_data)
}

pub fn get_oracle_config(
  oracle_specs: CharlieTokenSpecs,
  feedToken: Asset,
) -> (PolicyId, Int) {
  expect Some(token_pairs) = pairs.get_first(oracle_specs, feedToken.policyId)
  expect Some(result) = pairs.get_first(token_pairs, feedToken.assetName)
  result
}
