use aiken/collection/dict
use aiken/collection/list
use aiken/option
use aiken/primitive/bytearray
use cardano/assets.{PolicyId, tokens}
use cardano/transaction.{OutputReference, Transaction, find_input}
use fluidtokens/utils

pub type BondRedeemer {
  inputRef: OutputReference,
}

//borrower == 0
//lender == 1
validator bond(_bondType: Int) {
  mint(redeemer: BondRedeemer, policy_id: PolicyId, self: Transaction) {
    let inputRefHash = utils.hash_output_ref(redeemer.inputRef)
    let isInputRefSpent =
      option.is_some(find_input(self.inputs, redeemer.inputRef))
    let isEachMintedTokenAccountedFor =
      list.indexed_foldr(
        dict.to_pairs(tokens(self.mint, policy_id)),
        True,
        fn(index, Pair(assetName, quantity), result) {
          expect result

          if quantity > 0 {
            let correctAssetName = and {
                bytearray.at(assetName, 0) == index,
                bytearray.drop(assetName, 1) == bytearray.drop(inputRefHash, 1),
              }
            and {
              correctAssetName,
              quantity == 1,
            }
          } else {
            //Burning the tokens is always allowed
            True
          }
        },
      )
    and {
      isInputRefSpent,
      //We don't need to check of a possible overflow (> 255) as if it happens the minted NFT is not unique anymore and the mint will fail
      isEachMintedTokenAccountedFor,
    }
  }

  else(_) {
    fail
  }
}
