//// NFT Pointers
//// This module is for upgradable contracts. Already public.

use aiken/dict.{Dict}
use aiken/hash.{Blake2b_224, Hash}
use aiken/list
use aiken/transaction.{Input, Output}
use aiken/transaction/credential.{
  Address, Credential, Inline, StakeCredential, VerificationKey,
  VerificationKeyCredential,
}
use aiken/transaction/value.{quantity_of}

fn cred_validator(
  validating_credential: Credential,
  withdrawals: Pairs<StakeCredential, Int>,
  extra_signatories: List<Hash<Blake2b_224, VerificationKey>>,
) -> Bool {
  when validating_credential is {
    VerificationKeyCredential(pubkey_hash) ->
      list.any(extra_signatories, fn(signatory) { signatory == pubkey_hash })
    //TODO READD script_credential -> dict.has_key(withdrawals, Inline(script_credential))
    _ -> True
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
  withdrawals: Pairs<StakeCredential, Int>,
  extra_signatories: List<Hash<Blake2b_224, VerificationKey>>,
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
