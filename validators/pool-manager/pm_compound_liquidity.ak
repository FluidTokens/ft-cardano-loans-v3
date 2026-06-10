use cardano/address.{Credential, Script}
use cardano/transaction.{Transaction, Withdraw}
use fluidtokens/types/lender_manager.{LenderManagerWithdrawRedeemer} as lm
use fluidtokens/types/pool.{PoolWithdrawRedeemer} as pw
use fluidtokens/types/pool_manager.{CompoundLiquidityActionWithdrawRedeemer}
use fluidtokens/utils.{safe_list_at}

validator poolManager(
  lenderManagerWithdrawScriptHash: ByteArray,
  poolWithdrawScriptHash: ByteArray,
) {
  withdraw(
    redeemer: CompoundLiquidityActionWithdrawRedeemer,
    _credential: Credential,
    self: Transaction,
  ) {
    let poolWithdrawRedeemer =
      safe_list_at(self.redeemers, redeemer.poolWithdrawRedeemerIndex)
    expect poolWithdrawRedeemer.1st == Withdraw(Script(poolWithdrawScriptHash))
    expect poolRedeemer: PoolWithdrawRedeemer = poolWithdrawRedeemer.2nd

    let poolCompoundActionCalled =
      when poolRedeemer.action is {
        //The Lender Manager already ensures that 1 pool <-> 1 pool manager
        pw.Compound { .. } -> True
        _ -> False
      }

    //CompoundLiquidity action must be executed
    let lenderManagerWithdrawRedeemer =
      safe_list_at(self.redeemers, redeemer.lenderManagerWithdrawRedeemerIndex)
    expect
      lenderManagerWithdrawRedeemer.1st == Withdraw(
        Script(lenderManagerWithdrawScriptHash),
      )
    expect lenderManagerRedeemer: LenderManagerWithdrawRedeemer =
      lenderManagerWithdrawRedeemer.2nd

    let lenderManagerCompoundActionCalled =
      when lenderManagerRedeemer.action is {
        lm.Compound { .. } -> True
        lm.LiquidatePayInAdvanceAndCompound { .. } -> True
        lm.LiquidateConvertAndCompound { .. } -> True
        _ -> False
      }

    and {
      poolCompoundActionCalled,
      lenderManagerCompoundActionCalled,
    }
  }

  else(_) {
    fail
  }
}
