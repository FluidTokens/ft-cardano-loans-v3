use aiken/collection/list
use cardano/address.{Address, Credential, Inline, Script, StakeCredential}
use cardano/transaction.{Input, Output}

pub fn is_output_to_smart_credential(
  output: Output,
  credential: Credential,
  stakeCredential: Option<StakeCredential>,
  smartTokensSpendScriptHash: ByteArray,
) {
  or {
    //Native tokens
    output.address.payment_credential == credential,
    output.address.stake_credential == stakeCredential,
    //Smart tokens or native tokens accidentally sent to the smart account
    and {
      output.address.payment_credential == Script(smartTokensSpendScriptHash),
      output.address.stake_credential == Some(Inline(credential)),
    },
  }
}

pub fn get_outputs_to_smart_credential(
  outputs: List<Output>,
  credential: Credential,
  smartTokensSpendScriptHash: ByteArray,
) {
  list.filter(
    outputs,
    fn(output) {
      or {
        //Native tokens
        output.address.payment_credential == credential,
        //Smart tokens (or native tokens accidentally sent to the smart account)
        and {
          output.address.payment_credential == Script(
            smartTokensSpendScriptHash,
          ),
          output.address.stake_credential == Some(Inline(credential)),
        },
      }
    },
  )
}

pub fn get_inputs_from_smart_credential(
  inputs: List<Input>,
  credential: Credential,
  smartTokensSpendScriptHash: ByteArray,
) -> List<Input> {
  list.filter(
    inputs,
    fn(input) {
      or {
        //Native tokens
        input.output.address.payment_credential == credential,
        //Smart tokens (or native tokens accidentally sent to the smart account)
        and {
          input.output.address.payment_credential == Script(
            smartTokensSpendScriptHash,
          ),
          input.output.address.stake_credential == Some(Inline(credential)),
        },
      }
    },
  )
}

pub fn get_outputs_to_sc(
  outputs: List<Output>,
  spendValidatorScriptHash: ByteArray,
  smartTokensSpendScriptHash: ByteArray,
) {
  list.filter(
    outputs,
    fn(output) {
      or {
        //Native tokens
        output.address.payment_credential == Script(spendValidatorScriptHash),
        //Smart tokens or native tokens accidentally sent to the smart account
        and {
          output.address.payment_credential == Script(
            smartTokensSpendScriptHash,
          ),
          output.address.stake_credential == Some(
            Inline(Script(spendValidatorScriptHash)),
          ),
        },
      }
    },
  )
}

pub fn get_inputs_from_sc(
  inputs: List<Input>,
  spendValidatorScriptHash: ByteArray,
  smartTokensSpendScriptHash: ByteArray,
) -> List<Input> {
  list.filter(
    inputs,
    fn(input) {
      or {
        //Native tokens
        input.output.address.payment_credential == Script(
          spendValidatorScriptHash,
        ),
        //Smart tokens or native tokens accidentally sent to the smart account
        and {
          input.output.address.payment_credential == Script(
            smartTokensSpendScriptHash,
          ),
          input.output.address.stake_credential == Some(
            Inline(Script(spendValidatorScriptHash)),
          ),
        },
      }
    },
  )
}
