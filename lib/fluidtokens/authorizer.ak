use aiken/builtin
use aiken/collection/dict.{to_pairs}
use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Address, Credential, Script, VerificationKey}
use cardano/assets.{Lovelace, quantity_of, tokens}
use cardano/transaction.{Input, Output}
use fluidtokens/types/general.{
  Authorization, CardanoMintScript, CardanoSignature, CardanoSpendScript,
  CardanoWithdrawScript,
}

//TODO Letting the redeemers decide the auth.method, what are the chances that a script and a wallet have the same hash?
pub fn authorize_action(auth: Authorization) -> Bool {
  when auth.method is {
    // If the authorization method is PubKey, validate using the provided signature.
    CardanoSignature(extra_signatories) ->
      list.has(extra_signatories, auth.hash)
    // If the authorization method is SpendScript, ensure the Utxo is present in the transaction inputs.
    CardanoSpendScript(transaction_inputs) -> {
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
    CardanoWithdrawScript(withdrawals) -> {
      let credential = Script(auth.hash)
      pairs.has_key(withdrawals, credential)
    }
    // If the authorization method is MintScript, ensure the minted tokens meet the policy ID requirements and have a non-zero quantity.
    CardanoMintScript(transaction_mint) -> {
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

pub fn authorize_via_credential(
  validating_credential: Credential,
  withdrawals: Pairs<Credential, Lovelace>,
  extra_signatories: List<VerificationKeyHash>,
) -> Bool {
  when validating_credential is {
    VerificationKey(pubkey_hash) ->
      authorize_action(
        Authorization(CardanoSignature(extra_signatories), pubkey_hash),
      )
    Script(script_hash) ->
      authorize_action(
        Authorization(CardanoWithdrawScript(withdrawals), script_hash),
      )
  }
}

//True if the tx has a ref_input with the NFT inside and the owner:
//- signed the tx if it's a wallet
//- is a withdraw script in the withdrawals if it's a script
pub fn authorize_via_nft_ownership(
  nft_policy_id: ByteArray,
  nft_asset_name: ByteArray,
  reference_inputs: List<Input>,
  withdrawals: Pairs<Credential, Lovelace>,
  extra_signatories: List<VerificationKeyHash>,
) -> Bool {
  when
    reference_inputs
      |> list.find(
          fn(inp) {
            quantity_of(inp.output.value, nft_policy_id, nft_asset_name) >= 1
          },
        )
  is {
    Some(Input {
      output: Output { address: Address { payment_credential, .. }, .. },
      ..
    }) ->
      payment_credential
        |> authorize_via_credential(withdrawals, extra_signatories)
    _ -> False
  }
}
