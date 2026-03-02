use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use cardano/address.{Address, Credential, Script}
use cardano/assets.{ada_policy_id, add, flatten, quantity_of}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use fluidtokens/types/general.{Asset}
use fluidtokens/types/lender_manager.{
  LMCompoundWithdrawRedeemer, LenderManagerDatum,
} as lm
use fluidtokens/types/pool.{PoolDatum}
use fluidtokens/types/pool_manager.{PoolManagerDatum}
use fluidtokens/types/repayment.{RepaymentDatumWithToken} as r
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator actionValidator(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  lenderManagerSpendScriptHash: ByteArray,
  poolManagerSpendScriptHash: ByteArray,
  poolManagerPolicyId: ByteArray,
  repaymentPolicyId: ByteArray,
) {
  withdraw(
    redeemer: LMCompoundWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    let config =
      utils.get_config_as_data_list(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let smartTokensSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 0))
    let poolSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 8))
    let poolPolicyId = builtin.un_b_data(utils.safe_list_at(config, 2))
    let lmInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(lenderManagerSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )
    let poolManagerInputs =
      list.filter(
        self.inputs,
        fn(input) {
          input.output.address.payment_credential == Script(
            poolManagerSpendScriptHash,
          )
        },
      )
    let poolManagerOutputs =
      list.filter(
        self.outputs,
        fn(output) {
          output.address.payment_credential == Script(
            poolManagerSpendScriptHash,
          )
        },
      )
    let poolInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(poolSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )
    let poolOutputs =
      get_outputs_to_smart_credential(
        self.outputs,
        Script(poolSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )
    let (lenderBondInputs, lmAssetsInputs) =
      list.partition(
        lmInputs,
        fn(input) {
          expect InlineDatum(inputDatum) = input.output.datum
          if inputDatum is LenderManagerDatum {
            True
          } else {
            //We still expect the datum to be RepaymentDatumWithToken here
            False
          }
        },
      )
    //Lender bonds always reside in lender_manager.ak, so we don't need to consider CIP113 utxos
    let lenderBondOutputs =
      list.filter(
        self.outputs,
        fn(output) {
          output.address.payment_credential == Script(
            lenderManagerSpendScriptHash,
          )
        },
      )
    //Add repayments sitting in the lm to the total to compound for each pool manager
    let totalAssetsToCompoundForEachPoolManager =
      list.indexed_foldr(
        lmAssetsInputs,
        dict.empty,
        fn(index, assetInput, result) {
          expect InlineDatum(assetInputDatum) = assetInput.output.datum
          expect RepaymentDatumWithToken { ownerAsset, .. } = assetInputDatum

          let lenderBondIndex =
            safe_list_at(redeemer.lenderBondInputIndexes, index)

          let lenderBondInput = safe_list_at(lenderBondInputs, lenderBondIndex)
          expect InlineDatum(inputLenderBondDatum) =
            lenderBondInput.output.datum
          expect LenderManagerDatum { principalAsset, poolManagerId, .. } =
            inputLenderBondDatum
          let assetAmount =
            quantity_of(
              assetInput.output.value,
              principalAsset.policyId,
              principalAsset.assetName,
            )

          let receiptNFTCount =
            utils.quantity_of_policy_id(
              assetInput.output.value,
              repaymentPolicyId,
            )

          expect
            if principalAsset.policyId == ada_policy_id {
              // 1. If principal asset is ADA, ensure no other tokens are present, except eventual receipt NFT
              list.length(flatten(assetInput.output.value)) == 1 + receiptNFTCount
            } else {
              // 2. If principal asset is not ADA, ensure only min-ADA and principal token are present, except eventual receipt NFT
              list.length(flatten(assetInput.output.value)) == 2 + receiptNFTCount
            }

          //Selected lender bond must correspond to the ownerAsset of the datum
          expect
            quantity_of(
              lenderBondInput.output.value,
              ownerAsset.policyId,
              ownerAsset.assetName,
            ) == 1

          dict.insert_with(
            result,
            poolManagerId,
            assetAmount,
            fn(_k, a, b) { Some(a + b) },
          )
        },
      )

    let allCompoundedPoolsAreCorrect =
      utils.indexed_all(
        poolManagerInputs,
        fn(index, poolManagerInput) {
          let poolManagerId = safe_list_at(redeemer.poolManagerIds, index)
          expect Some(addedLiquidity) =
            dict.get(totalAssetsToCompoundForEachPoolManager, poolManagerId)
          let poolManagerOutput = safe_list_at(poolManagerOutputs, index)
          let poolInputIndex = safe_list_at(redeemer.poolInputIndexes, index)
          let poolInput = safe_list_at(poolInputs, poolInputIndex)
          let poolOutput = safe_list_at(poolOutputs, poolInputIndex)
          expect InlineDatum(poolManagerDatum) = poolManagerInput.output.datum
          expect PoolManagerDatum {
            poolId,
            poolOwnerAuth,
            compoudingFeePerMille,
          } = poolManagerDatum
          expect InlineDatum(oldPoolDatum) = poolInput.output.datum
          expect PoolDatum { commonData, .. } = oldPoolDatum
          let newPoolId = safe_list_at(redeemer.compoundedPoolNewIds, index)
          let compoundingFee = addedLiquidity * compoudingFeePerMille / 1000
          //Replace old liquidity with new one and replace old pool nft with new one
          let expectedNewPoolValue =
            poolInput.output.value
              |> add(
                  commonData.principalAsset.policyId,
                  commonData.principalAsset.assetName,
                  addedLiquidity - compoundingFee,
                )
              |> add(poolPolicyId, poolId, -1)
              |> add(poolPolicyId, newPoolId, 1)

          and {
            //If poolManagerId is "", no compounding allowed so the whole action must fail
            poolManagerId != "",
            //Input poolManager must contain the NFT specified in the lender bond datums
            quantity_of(
              poolManagerInput.output.value,
              poolManagerPolicyId,
              poolManagerId,
            ) == 1,
            //Pool must be the one specified in the poolManager datum
            quantity_of(poolInput.output.value, poolPolicyId, poolId) == 1,
            //Pool must be same in address and datum except for value
            builtin.equals_data(poolOutput.datum, poolInput.output.datum),
            builtin.equals_data(poolOutput.value, expectedNewPoolValue),
            builtin.equals_data(poolOutput.address, poolInput.output.address),
            //PoolManager must be same in input and output except for the poolId
            builtin.equals_data(
              poolManagerOutput.address,
              poolManagerInput.output.address,
            ),
            builtin.equals_data(
              poolManagerOutput.value,
              poolManagerInput.output.value,
            ),
            builtin.equals_data(
              poolManagerOutput.datum,
              InlineDatum(
                PoolManagerDatum {
                  poolOwnerAuth,
                  poolId: newPoolId,
                  compoudingFeePerMille,
                },
              ),
            ),
          }
        },
      )

    let allLenderBondsAreCorrect =
      utils.indexed_all(
        lenderBondInputs,
        fn(index, lenderBondInput) {
          let lenderBondOutput = safe_list_at(lenderBondOutputs, index)

          //Output with lender bond must be the same as input
          builtin.equals_data(lenderBondInput.output, lenderBondOutput)
        },
      )

    and {
      //All pool managers in input must have been used for compounding
      list.length(poolManagerInputs) == list.length(
        dict.to_pairs(totalAssetsToCompoundForEachPoolManager),
      ),
      //No additional pools spent
      list.length(poolManagerInputs) == list.length(poolInputs),
      //All compounded pools are correct
      allCompoundedPoolsAreCorrect,
      //All spent lender bonds return correctly to the sc
      allLenderBondsAreCorrect,
    }
  }

  else(_) {
    fail
  }
}
