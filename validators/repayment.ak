use aiken/list
use aiken/transaction.{ScriptContext, Spend}
use types.{RepaymentDatum}
use utils.{is_nft_spent}

type Redeemer {
  Withdraw {
    //This is the absolute input index that contains the lender bond
    bondInputIndex: Int,
  }
}

validator(lendersNftCs: ByteArray) {
  fn spend(
    datum: RepaymentDatum,
    redeemer: Redeemer,
    ctx: ScriptContext,
  ) -> Bool {
    when ctx.purpose is {
      Spend(_) -> {
        let Withdraw(bondInputIndex) = redeemer
        expect Some(input) = list.at(ctx.transaction.inputs, bondInputIndex)
        is_nft_spent(lendersNftCs, datum.lenderNFT, input)
      }
      _ -> False
    }
  }
}
