use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use cardano/address.{Address, Credential, Script}
use cardano/assets.{add, quantity_of}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use fluidtokens/types/general.{Asset}
use fluidtokens/types/lender_smart_manager.{
  LSMCompoundWithdrawRedeemer, LenderSmartManagerDatum,
} as lsm
use fluidtokens/types/pool.{PoolDatum}
use fluidtokens/types/pool_smart_manager.{PoolSmartManagerDatum}
use fluidtokens/types/repayment.{RepaymentDatumWithToken} as r
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator actionValidator(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  lenderSmartManagerSpendScriptHash: ByteArray,
  poolManagerSpendScriptHash: ByteArray,
  poolManagerPolicyId: ByteArray,
) {
  withdraw(
    redeemer: LSMCompoundWithdrawRedeemer,
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
    let lsmInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(lenderSmartManagerSpendScriptHash),
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
    let (lenderBondInputs, lsmAssetsInputs) =
      list.partition(
        lsmInputs,
        fn(input) {
          expect InlineDatum(inputDatum) = input.output.datum
          if inputDatum is LenderSmartManagerDatum {
            True
          } else {
            //We still expect the datum to be RepaymentDatumWithToken here
            False
          }
        },
      )
    //Outputs to this sc are all lender bonds, as the compounded assets are sent to the pool
    let lenderBondOutputs =
      get_outputs_to_smart_credential(
        self.outputs,
        Script(lenderSmartManagerSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )
    //Add repayments sitting in the lsm to the total to compound for each pool manager
    let totalAssetsToCompoundForEachPoolManager =
      dict.to_pairs(
        list.indexed_foldr(
          lsmAssetsInputs,
          dict.empty,
          fn(index, assetInput, result) {
            expect InlineDatum(assetInputDatum) = assetInput.output.datum
            expect RepaymentDatumWithToken { ownerAsset, .. } = assetInputDatum

            let lenderBondIndex =
              safe_list_at(redeemer.lenderBondInputIndexes, index)

            let lenderBondInput =
              safe_list_at(lenderBondInputs, lenderBondIndex)
            expect InlineDatum(inputLenderBondDatum) =
              lenderBondInput.output.datum
            expect LenderSmartManagerDatum { principalAsset, poolManagerId, .. } =
              inputLenderBondDatum
            let assetAmount =
              quantity_of(
                assetInput.output.value,
                principalAsset.policyId,
                principalAsset.assetName,
              )

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
        ),
      )

    let allCompoundedPoolsAreCorrect =
      list.indexed_foldr(
        totalAssetsToCompoundForEachPoolManager,
        True,
        fn(index, Pair(poolManagerId, addedLiquidity), result) {
          //As all inputs must return True, if any of previous input returned False, then fail
          //The last input is not checked but will return its value at the end, so if False withdraw will fail
          expect result
          //TODO Is the index ok to select input and output?
          let poolManagerInput = safe_list_at(poolManagerInputs, index)
          let poolManagerOutput = safe_list_at(poolManagerOutputs, index)
          //TODO Is the index ok to select input and output?
          let poolInput = safe_list_at(poolInputs, index)
          let poolOutput = safe_list_at(poolOutputs, index)
          expect InlineDatum(poolManagerDatum) = poolManagerInput.output.datum
          expect PoolSmartManagerDatum {
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
                PoolSmartManagerDatum {
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
      list.indexed_foldr(
        lenderBondInputs,
        True,
        fn(index, lenderBondInput, result) {
          //As all inputs must return True, if any of previous input returned False, then fail
          //The last input is not checked but will return its value at the end, so if False withdraw will fail
          expect result

          let lenderBondOutput = safe_list_at(lenderBondOutputs, index)

          //Output with lender bond must be the same as input
          builtin.equals_data(lenderBondInput.output, lenderBondOutput)
        },
      )

    and {
      //All pool managers in input must have been used for compounding
      list.length(poolManagerInputs) == list.length(
        totalAssetsToCompoundForEachPoolManager,
      ),
      //No additional pools spent
      list.length(poolManagerInputs) == list.length(poolInputs),
      //All compounded pool are correct
      allCompoundedPoolsAreCorrect,
      //All spent lender bonds return correctly to the sc
      allLenderBondsAreCorrect,
    }
  }

  else(_) {
    fail
  }
}
