use aiken/collection/list
use cardano/address.{Address, Inline, VerificationKey}
use cardano/transaction.{Input, Output}

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
        output.address.payment_credential == VerificationKey(
          spendValidatorScriptHash,
        ),
        //Smart tokens or native tokens accidentally sent to the smart account
        and {
          output.address.payment_credential == VerificationKey(
            smartTokensSpendScriptHash,
          ),
          output.address.stake_credential == Some(
            Inline(VerificationKey(spendValidatorScriptHash)),
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
        input.output.address.payment_credential == VerificationKey(
          spendValidatorScriptHash,
        ),
        //Smart tokens or native tokens accidentally sent to the smart account
        and {
          input.output.address.payment_credential == VerificationKey(
            smartTokensSpendScriptHash,
          ),
          input.output.address.stake_credential == Some(
            Inline(VerificationKey(spendValidatorScriptHash)),
          ),
        },
      }
    },
  )
}
