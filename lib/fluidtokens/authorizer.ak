use aiken/builtin
use aiken/collection/dict.{to_pairs}
use aiken/collection/list
use aiken/collection/pairs
use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Address, Credential, Script, VerificationKey}
use cardano/assets.{Lovelace, Value, quantity_of, tokens}
use cardano/transaction.{Input, Output}
use fluidtokens/types/general.{
  Authorization, CardanoMintScript, CardanoSignature, CardanoSpendScript,
  CardanoWithdrawScript,
}

fn cred_validator(
  validating_credential: Credential,
  withdrawals: Pairs<Credential, Lovelace>,
  extra_signatories: List<VerificationKeyHash>,
) -> Bool {
  when validating_credential is {
    VerificationKey(pubkey_hash) ->
      list.any(extra_signatories, fn(signatory) { signatory == pubkey_hash })
    Script(_script_hash) -> pairs.has_key(withdrawals, validating_credential)
  }
}

/// Find nft from reference, use its payment credential in cred_validator.
/// Where this is used, the script should fail if this returns false (but this function is pure)
pub fn nft_validator(
  nft_policy: ByteArray,
  // Gov NFT policy
  nft_name: ByteArray,
  // Gov NFT name
  reference_inputs: List<Input>,
  withdrawals: Pairs<Credential, Lovelace>,
  extra_signatories: List<VerificationKeyHash>,
) -> Bool {
  when
    reference_inputs
      |> list.find(
          fn(inp) { quantity_of(inp.output.value, nft_policy, nft_name) == 1 },
        )
  is {
    Some(Input {
      output: Output { address: Address { payment_credential, .. }, .. },
      ..
    }) -> payment_credential |> cred_validator(withdrawals, extra_signatories)
    _ -> False
  }
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
