use aiken/collection/dict
use aiken/collection/list
use aiken/option
use cardano/assets.{PolicyId, tokens}
use cardano/transaction.{OutputReference, Transaction, find_input}
use fluidtokens/utils

pub type BondRedeemer {
  inputRefs: List<OutputReference>,
}

//borrower == 0
//lender == 1
validator bond(_bondType: Int) {
  mint(redeemer: BondRedeemer, policy_id: PolicyId, self: Transaction) {
    let isEachMintedTokenAccountedFor =
      list.indexed_foldr(
        dict.to_pairs(tokens(self.mint, policy_id)),
        True,
        fn(index, Pair(assetName, quantity), result) {
          expect result

          if quantity > 0 {
            expect Some(inputRef) = list.at(redeemer.inputRefs, index)
            let inputRefHash = utils.hash_output_ref(inputRef)
            let isInputRefSpent =
              option.is_some(find_input(self.inputs, inputRef))
            let correctAssetName = assetName == inputRefHash
            and {
              isInputRefSpent,
              correctAssetName,
              quantity == 1,
            }
          } else {
            //Burning the tokens is always allowed
            True
          }
        },
      )
    isEachMintedTokenAccountedFor
  }

  else(_) {
    fail
  }
}
