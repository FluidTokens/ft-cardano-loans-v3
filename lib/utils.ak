use aiken/collection/dict
use aiken/collection/list.{length}
use aiken/interval.{Finite}
use cardano/address.{Address, Inline, Script, VerificationKey}
use cardano/assets.{AssetName, PolicyId, Value, quantity_of}
use cardano/transaction.{
  Input, Output, OutputReference, Redeemer, ScriptPurpose, Spend, Transaction,
  Withdraw,
}
use types/general.{Asset}
use types/redeemer.{
  Aggregated, Dedicated, OraclePriceFeed, OracleRedeemer, Pooled,
}

pub fn is_nft_burnt(policyId: PolicyId, assetName: AssetName, mints: Value) {
  quantity_of(mints, policyId, assetName) == -1
}

pub fn is_nft_spent(
  policyId: PolicyId,
  assetName: AssetName,
  inputWithBond: Input,
) {
  quantity_of(inputWithBond.output.value, policyId, assetName) == 1
}

pub fn validity_range_within_an_hour(tx: Transaction) {
  when tx.validity_range.upper_bound.bound_type is {
    Finite(end) ->
      when tx.validity_range.lower_bound.bound_type is {
        Finite(start) -> end - start <= 3600000
        // 1 hour in millis
        _ -> False
      }
    _ -> False
  }
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

pub fn get_own_hash(output_reference: OutputReference, txInputs: List<Input>) {
  expect Some(input) =
    list.find(txInputs, fn(x) { x.output_reference == output_reference })

  when input.output.address.payment_credential is {
    Script(hash) -> hash
    _ -> fail
  }
}

pub fn tokens_sent_to_lender_and_borrower(
  txOutputs: List<Output>,
  assetName: AssetName,
  lenderAddress: Address,
  borrowerAddress: Address,
  borrowersNftCs: ByteArray,
  lendersNftCs: ByteArray,
) {
  let outputListToLenderAndBorrower = list.filter(txOutputs, fn(output) { or {
          and {
            output.address == lenderAddress,
            quantity_of(output.value, lendersNftCs, assetName) == 1,
          },
          and {
            output.address == borrowerAddress,
            quantity_of(output.value, borrowersNftCs, assetName) == 1,
          },
        } })

  length(outputListToLenderAndBorrower) == 2
}

pub fn retrieve_oracle_data(
  oracleInput: Input,
  redeemers: Pairs<ScriptPurpose, Redeemer>,
  transaction_valid_to: Int,
) -> Option<OraclePriceFeed> {
  expect Some(loan_oracle_redeemer) = None
  //TODO Readd this dict.get(redeemers, Withdraw(oracleInput.output.address.payment_credential))
  expect loan_tokens_price: OracleRedeemer = loan_oracle_redeemer

  when loan_tokens_price.data is {
    Pooled(data) ->
      if data.valid_to >= transaction_valid_to {
        Some(Pooled(data))
      } else {
        trace @"oracle is expired"
        None
      }
    Aggregated(data) ->
      if data.valid_to >= transaction_valid_to {
        Some(Aggregated(data))
      } else {
        trace @"oracle is expired"
        None
      }
    Dedicated(data) ->
      if data.valid_to >= transaction_valid_to {
        Some(Dedicated(data))
      } else {
        trace @"oracle is expired"
        None
      }
  }
}
