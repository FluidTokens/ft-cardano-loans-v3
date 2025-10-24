// POSSIBLE POOL ACTIONS:
// - new -> no auth, new pool nft
// - borrow -> no auth, no new pool nft
// - cancel -> auth, no new pool nft
// - edit (cancel+new) -> auth, new pool nft
// - compound (cancel+new) -> auth, new pool nft

// poolManager points to a pool nft 
// -> a lsm points to the poolManager nft that doesn't change
// -> when a pool nft changes, poolManager also changes its pointing.

// Example: pool nft "A", poolManager nft "B" with datum pool="A". LSM points to "B". 
// Pool edited, new pool nft "C", updated "B" datum with pool="C", no need to change LSM. 
// Pool compounded, new pool nft "D", updated "B" datum with pool="D", no need to change LSM.
// Pool cancelled, "B" can also be burnt. LSM point to a poolManager that doesn't exist anymore.

// 1) poolManager nft mint:
// 	1) No pools are spent
// 	2) A pool nft must be minted
// 	3) poolManager nft must have the same pool nft assetname
// 	4) poolManager nft must go to poolManager spend script
// 	5) poolManager nft must have datum with auth=poolOwner and poolId = pool nft
// 2) poolManager nft burn:
// 	1) True
// 3) poolManager spend:
// 	1) poolManager withdraw executed
// 4) poolManager withdraw:
// 	1) CancelPoolManager -> auth signing + burn poolManager nft
// 	2) UpdatePoolManager -> auth signing
// 			+ poolManager output same value and destination 
// 			+ poolManager output datum must be of inline type PoolManagerDatum
// 	3) CompoundLiquidity -> lsm CompoundLiquidity action is executed
// 5) lsm CompoundLiquidity:
// 	1) Sum liquidity for each different poolManager
//	2) For each liquidity utxo, ensure the correct lenderBond is being spent and goes back unchanged
//	3) Ensure length(poolManagerInputs) == length(totalAddedLiquidityForEachPool)
//	4) Ensure length((poolManagerInputs) == length(poolInputs)
// 	5) For each poolManagerInput:
// 		1) Ensure it really has the expected nft
// 		2) Correct pool must be in input (= have the nft written in the PoolManager datum)
// 		3) Correct pool must be in output (same datum and address + new value is correct)
// 		4) Correct poolManager in output (same datum except new poolId + same value and address)

use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/transaction.{Transaction}
use fluidtokens/types/lender_smart_manager.{
  Compound, LenderSmartManagerWithdrawRedeemer, Liquidate, LiquidateAndConvert,
  LiquidateAndPayInAdvance, LiquidateConvertAndCompound,
  LiquidatePayInAdvanceAndCompound, WithdrawAssets, WithdrawBonds,
} as lsm

validator lenderSmartManager(
  lsmWithdrawBondsActionScriptHash: ByteArray,
  lsmWithdrawAssetsActionScriptHash: ByteArray,
  lsmLiquidateActionScriptHash: ByteArray,
  lsmCompoundActionScriptHash: ByteArray,
  lsmLiquidateAndPayInAdvanceActionScriptHash: ByteArray,
  lsmLiquidateAndConvertActionScriptHash: ByteArray,
  lsmLiquidatePayInAdvanceAndCompoundActionScriptHash: ByteArray,
  lsmLiquidateConvertAndCompoundActionScriptHash: ByteArray,
) {
  withdraw(
    redeemer: LenderSmartManagerWithdrawRedeemer,
    _credential: Credential,
    self: Transaction,
  ) {
    let actionWithdrawScriptHash =
      when redeemer.action is {
        WithdrawBonds -> lsmWithdrawBondsActionScriptHash
        WithdrawAssets { .. } -> lsmWithdrawAssetsActionScriptHash
        Liquidate { .. } -> lsmLiquidateActionScriptHash
        Compound { .. } -> lsmCompoundActionScriptHash
        LiquidateAndPayInAdvance { .. } ->
          lsmLiquidateAndPayInAdvanceActionScriptHash
        LiquidateAndConvert { .. } -> lsmLiquidateAndConvertActionScriptHash
        LiquidatePayInAdvanceAndCompound { .. } ->
          lsmLiquidatePayInAdvanceAndCompoundActionScriptHash
        LiquidateConvertAndCompound { .. } ->
          lsmLiquidateConvertAndCompoundActionScriptHash
      }

    list.any(
      self.withdrawals,
      fn(withdrawal) {
        when withdrawal is {
          Pair(Script(scriptHash), _amnt) ->
            scriptHash == actionWithdrawScriptHash
          _ -> False
        }
      },
    )
  }

  else(_) {
    fail
  }
}
