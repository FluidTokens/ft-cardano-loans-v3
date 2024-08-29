use aiken/transaction.{ScriptContext, Spend}
use types.{BondsGraveyardDatum}
use utils.{must_be_signed_by}

type Redeemer {
  Redeemer
}

validator {
  fn spend(
    datum: BondsGraveyardDatum,
    _redeemer: Redeemer,
    ctx: ScriptContext,
  ) -> Bool {
    when ctx.purpose is {
      Spend(_) -> must_be_signed_by(ctx.transaction, datum.ownerAddress)
      _ -> False
    }
  }
}
