//Given an unique list of input utxos (and indexes), it allows minting of 1 NFT for each utxo.
//The order of the input utxos must be the same of the minted NFTs from this script.
//Given an input sc hash, in the same tx you can burn an amount of NFTs corresponding to the number of inputs from that sc. 
//If you only want to only burn, just pass ([], yourInputContractHash) as redeemer.
use aiken/bytearray
use aiken/hash.{sha2_256}
use aiken/list.{length}
use aiken/transaction.{
  Input, Mint, OutputReference, ScriptContext, ScriptPurpose, TransactionId,
}
use aiken/transaction/credential.{ScriptCredential}
use aiken/transaction/value.{flatten, from_minted_value}

//we pass in the redeemer the transaction to look for
type Redeemer {
  MintBonds {
    utxosAndIndexes: List<(ByteArray, Int)>,
    inputContractHash: ByteArray,
  }
}

//borrower == 0
//lender == 1
validator(_bondType: Int) {
  fn minter(redeemer: Redeemer, ctx: ScriptContext) {
    //the policy is evaluated from the tx purpose
    let policy: ByteArray = get_policy(ctx.purpose)
    //You can also burn a number of tokens equal to the number of redeemer contract inputs
    let MintBonds(utxosAndIndexes, inputContractHash) = redeemer
    let mintedTokens = flatten(from_minted_value(ctx.transaction.mint))
    let burntTokensWithThisPolicy = list.filter(mintedTokens, fn(x) { and {
            x.1st == policy,
            x.3rd < 0,
          } })

    let nBurntTokensEqualsNContractInputs =
      length(burntTokensWithThisPolicy) == n_inputs_from_contract(
        inputContractHash,
        ctx.transaction.inputs,
      )

    let mintedTokensWithThisPolicy = list.filter(mintedTokens, fn(x) { and {
            x.1st == policy,
            x.3rd > 0,
          } })

    //only burnt tokens
    if length(mintedTokensWithThisPolicy) == 0 {
      nBurntTokensEqualsNContractInputs
    } else if //only 1 token per name, they are nfts!
    list.any(mintedTokensWithThisPolicy, fn(x) { x.3rd > 1 }) {
      fail
    } else {
      and {
        nBurntTokensEqualsNContractInputs,
        all_redeemer_utxos_are_inputs_and_create_a_new_token(
          utxosAndIndexes,
          mintedTokensWithThisPolicy,
          ctx.transaction.inputs,
        ),
      }
    }
  }
}

fn all_redeemer_utxos_are_inputs_and_create_a_new_token(
  utxosAndIndexes: List<(ByteArray, Int)>,
  mintedTokensWithThisPolicy: List<(ByteArray, ByteArray, Int)>,
  inputs: List<Input>,
) {
  let expectedMintedTokenNamesThatHaveInput =
    list.map(
      utxosAndIndexes,
      fn(utxoAndIndex) {
        let utxo = utxoAndIndex.1st
        let index = utxoAndIndex.2nd

        let inputIncluded = input_is_included(utxo, index, inputs)
        let validUtxoId = index < 256

        if and {
          inputIncluded,
          validUtxoId,
        } {
          //tokenName is the hash of the concatenation of index and txId
          let tokenName = sha2_256(bytearray.push(utxo, index))

          tokenName
        } else {
          fail
        }
      },
    )

  list.map(mintedTokensWithThisPolicy, fn(x) { x.2nd }) == expectedMintedTokenNamesThatHaveInput
}

//get policyID of the
fn get_policy(purpose: ScriptPurpose) {
  expect Mint(policyId) = purpose
  policyId
}

fn n_inputs_from_contract(inputContractHash: ByteArray, txInputs: List<Input>) {
  length(
    list.filter(
      txInputs,
      fn(input) {
        when input.output.address.payment_credential is {
          ScriptCredential(hash) -> hash == inputContractHash
          _ -> False
        }
      },
    ),
  )
}

fn input_is_included(tx: ByteArray, index: Int, txInputs: List<Input>) {
  let id = TransactionId { hash: tx }
  let wanted = OutputReference { transaction_id: id, output_index: index }
  let inputList =
    list.filter(txInputs, fn(input) { input.output_reference == wanted })
  length(inputList) == 1
}
