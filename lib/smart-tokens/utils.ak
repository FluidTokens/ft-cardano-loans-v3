use aiken/collection/list
use cardano/address.{Address, Credential, Inline, Script, StakeCredential}
use cardano/transaction.{Input, Output}

//Ensures that the output is to a smart credential, either native tokens or smart tokens, both for wallets and smart contracts
pub fn is_output_to_smart_credential(
  output: Output,
  spendCredential: Credential,
  stakeCredential: Option<StakeCredential>,
  smartTokensSpendScriptHash: ByteArray,
) {
  or {
    //Native tokens
    and {
      output.address.payment_credential == spendCredential,
      output.address.stake_credential == stakeCredential,
    },
    //Smart tokens or native tokens accidentally sent to the smart account
    and {
      output.address.payment_credential == Script(smartTokensSpendScriptHash),
      output.address.stake_credential == Some(Inline(spendCredential)),
    },
  }
}

pub fn get_outputs_to_smart_credential(
  outputs: List<Output>,
  spendScriptCredential: Credential,
  withdrawScriptCredential: Credential,
  smartTokensSpendScriptHash: ByteArray,
) {
  list.filter(
    outputs,
    fn(output) {
      or {
        //Native tokens
        output.address.payment_credential == spendScriptCredential,
        //Smart tokens (or native tokens accidentally sent to the smart account)
        and {
          output.address.payment_credential == Script(
            smartTokensSpendScriptHash,
          ),
          output.address.stake_credential == Some(
            Inline(withdrawScriptCredential),
          ),
        },
      }
    },
  )
}

pub fn get_inputs_from_smart_credential(
  inputs: List<Input>,
  spendScriptCredential: Credential,
  withdrawScriptCredential: Credential,
  smartTokensSpendScriptHash: ByteArray,
) -> List<Input> {
  list.filter(
    inputs,
    fn(input) {
      or {
        //Native tokens
        input.output.address.payment_credential == spendScriptCredential,
        //Smart tokens (or native tokens accidentally sent to the smart account)
        and {
          input.output.address.payment_credential == Script(
            smartTokensSpendScriptHash,
          ),
          input.output.address.stake_credential == Some(
            Inline(withdrawScriptCredential),
          ),
        },
      }
    },
  )
}
