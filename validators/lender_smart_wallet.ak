// POSSIBLE POOL ACTIONS:
// - new -> no auth, new pool nft
// - borrow -> no auth, no new pool nft
// - cancel -> auth, no new pool nft
// - edit (cancel+new) -> auth, new pool nft
// - compound (cancel+new) -> auth, new pool nft

// poolManager points to a pool nft 
// -> a lsw points to the poolManager nft that doesn't change
// -> when a pool nft changes, poolManager also changes its pointing.

// Example: pool nft "A", poolManager nft "B" with datum pool="A". LSW points to "B". 
// Pool edited, new pool nft "C", updated "B" datum with pool="C", no need to change LSW. 
// Pool compounded, new pool nft "D", updated "B" datum with pool="D", no need to change LSW.
// Pool cancelled, "B" can also be burnt. LSW point to a poolManager that doesn't exist anymore.

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
// 	3) CompoundLiquidity -> lsw CompoundLiquidity action is executed
// 5) lsw CompoundLiquidity:
// 	1) Sum liquidity for each different poolManager
//	2) For each liquidity utxo, ensure the correct lenderBond is being spent and goes back unchanged
//	3) Ensure length(poolManagerInputs) == length(totalAddedLiquidityForEachPool)
//	4) Ensure length((poolManagerInputs) == length(poolInputs)
// 	5) For each poolManagerInput:
// 		1) Ensure it really has the expected nft
// 		2) Correct pool must be in input (= have the nft written in the PoolManager datum)
// 		3) Correct pool must be in output (same datum and address + new value is correct)
// 		4) Correct poolManager in output (same datum except new poolId + same value and address)

use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Script}
use cardano/assets.{add, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/constants
use fluidtokens/types/general.{Asset, CollateralAsset}
use fluidtokens/types/lender_smart_wallet.{
  ClaimLoans, CompoundLiquidity, ConvertToLiquidity, LenderSmartWalletDatum,
  LenderSmartWalletWithdrawRedeemer, WithdrawAssets, WithdrawBonds,
} as lsw
use fluidtokens/types/loan.{LoanDatum}
use fluidtokens/types/minswap_info.{MinswapV2Info}
use fluidtokens/types/minswap_v2_types as minswap
use fluidtokens/types/pool.{PoolDatum}
use fluidtokens/types/pool_smart_manager.{PoolSmartManagerDatum}
use fluidtokens/types/repayment.{RepaymentDatumWithToken} as r
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator lenderSmartWallet(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  lenderSmartWalletSpendScriptHash: ByteArray,
  minswapV2SpendScriptHash: ByteArray,
  minswapV2InfoNFTPolicyId: ByteArray,
  minswapV2InfoNFTAssetName: ByteArray,
  poolManagerSpendScriptHash: ByteArray,
  poolManagerPolicyId: ByteArray,
  loanWithdrawScriptHash: ByteArray,
) {
  withdraw(
    redeemer: LenderSmartWalletWithdrawRedeemer,
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
    let loanSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 10))
    let poolSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 8))
    let loanPolicyId = builtin.un_b_data(utils.safe_list_at(config, 6))
    let poolPolicyId = builtin.un_b_data(utils.safe_list_at(config, 2))
    let lenderBondPolicyId = builtin.un_b_data(utils.safe_list_at(config, 5))
    let lswInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(lenderSmartWalletSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )

    when redeemer.action is {
      WithdrawBonds ->
        list.foldr(
          lswInputs,
          True,
          fn(input, result) {
            //As all inputs must return True, if any of previous input returned False, then fail
            //The last input is not checked but will return its value at the end, so if False withdraw will fail
            expect result

            expect InlineDatum(inputDatum) = input.output.datum
            expect LenderSmartWalletDatum { lenderAuth, .. } = inputDatum
            authorize_action(
              create_auth(
                lenderAuth,
                self.inputs,
                self.withdrawals,
                self.extra_signatories,
                self.mint,
              ),
            )
          },
        )
      WithdrawAssets { lenderBondOutputIndexes } ->
        list.indexed_foldr(
          lswInputs,
          True,
          fn(index, input, result) {
            //As all inputs must return True, if any of previous input returned False, then fail
            //The last input is not checked but will return its value at the end, so if False withdraw will fail
            expect result

            expect InlineDatum(inputDatum) = input.output.datum
            expect RepaymentDatumWithToken { ownerAsset, .. } = inputDatum

            let lenderBondOutput =
              safe_list_at(
                self.outputs,
                safe_list_at(lenderBondOutputIndexes, index),
              )
            quantity_of(
              lenderBondOutput.value,
              lenderBondPolicyId,
              ownerAsset.assetName,
            ) == 1
          },
        )

      ClaimLoans { loanInputIndexes, loanIds } -> {
        let loanInputs =
          get_inputs_from_smart_credential(
            self.inputs,
            Script(loanSpendScriptHash),
            Script(loanWithdrawScriptHash),
            smartTokensSpendScriptHash,
          )
        let (lenderBondOutputs, claimedAssetsOutputs) =
          list.partition(
            get_outputs_to_smart_credential(
              self.outputs,
              Script(lenderSmartWalletSpendScriptHash),
              credential,
              smartTokensSpendScriptHash,
            ),
            fn(output) {
              expect InlineDatum(outputDatum) = output.datum
              if outputDatum is LenderSmartWalletDatum {
                True
              } else {
                //We still expect the datum to be RepaymentDatumWithToken here
                False
              }
            },
          )
        list.indexed_foldr(
          lswInputs,
          True,
          fn(index, input, result) {
            //As all inputs must return True, if any of previous input returned False, then fail
            //The last input is not checked but will return its value at the end, so if False withdraw will fail
            expect result

            expect InlineDatum(inputLenderBondDatum) = input.output.datum
            expect lenderBondDatum: LenderSmartWalletDatum =
              inputLenderBondDatum

            let loanInput =
              safe_list_at(loanInputs, safe_list_at(loanInputIndexes, index))
            expect InlineDatum(inputLoanDatum) = loanInput.output.datum
            expect loanDatum: LoanDatum = inputLoanDatum

            let claimedCollateralOutput =
              safe_list_at(claimedAssetsOutputs, index)
            let lenderBondOutput = safe_list_at(lenderBondOutputs, index)

            expect InlineDatum(claimedCollateralOutputDatum) =
              claimedCollateralOutput.datum
            expect RepaymentDatumWithToken { ownerAsset, action, data, .. } =
              claimedCollateralOutputDatum
            expect claimedAsset: CollateralAsset = data
            expect Some(claimedAssetName) = claimedAsset.maybeAssetName

            let loanId = safe_list_at(loanIds, index)

            let claimedAssetQuantity =
              quantity_of(
                loanInput.output.value,
                claimedAsset.policyId,
                claimedAssetName,
              )
            let botFee =
              lenderBondDatum.claimingFeePerMille * claimedAssetQuantity / 1000
            and {
              //Ensure input lender bond corresponds to the loan being claimed
              quantity_of(input.output.value, lenderBondPolicyId, loanId) == 1,
              //Output with lender bond must be the same as input
              builtin.equals_data(input.output, lenderBondOutput),
              //Output with claimed collateral must contain everything the loan had except the loan token
              // and bot fee, so it works only for full liquidations
              builtin.equals_data(
                loanInput.output.value,
                add(
                  add(claimedCollateralOutput.value, loanPolicyId, loanId, 1),
                  claimedAsset.policyId,
                  claimedAssetName,
                  botFee,
                ),
              ),
              //Output with claimed collateral must have correct datum
              ownerAsset.policyId == lenderBondPolicyId,
              ownerAsset.assetName == loanId,
              action == constants.claimed_collateral_action,
              claimedAsset == loanDatum.collateral,
              //Ensure the claimed collateral is sent to the correct address, considering CIP113
              if loanInput.output.address.payment_credential == Script(
                smartTokensSpendScriptHash,
              ) {
                claimedCollateralOutput.address == Address {
                  payment_credential: Script(smartTokensSpendScriptHash),
                  //TODO Should it be spendcredential of the lender?
                  stake_credential: lenderBondDatum.lenderStakeCredential,
                }
              } else {
                claimedCollateralOutput.address == Address {
                  payment_credential: Script(lenderSmartWalletSpendScriptHash),
                  //TODO Should it be spendcredential of the lender?
                  stake_credential: lenderBondDatum.lenderStakeCredential,
                }
              },
            }
          },
        )
      }

      ConvertToLiquidity {
        lenderBondRefInputsIndexes,
        minswapV2InfoRefInputIndex,
      } -> {
        let minswapV2InfoRefInput =
          safe_list_at(self.reference_inputs, minswapV2InfoRefInputIndex)
        expect InlineDatum(minswapV2InfoDatum) =
          minswapV2InfoRefInput.output.datum
        expect minswapV2Info: MinswapV2Info = minswapV2InfoDatum
        expect coerced: Pairs<ByteArray, (Asset, Bool)> =
          minswapV2Info.lpAssetForPoolAssetPairAndDirection
        let lpAssetForPoolAssetPairAndDirection =
          coerced |> dict.from_ascending_pairs

        //TODO Is credential correct here?
        let minswapOrderOutputs =
          get_outputs_to_smart_credential(
            self.outputs,
            Script(minswapV2SpendScriptHash),
            credential,
            smartTokensSpendScriptHash,
          )
        and {
          //MinswapV2Info ref input must contain the unique NFT
          quantity_of(
            minswapV2InfoRefInput.output.value,
            minswapV2InfoNFTPolicyId,
            minswapV2InfoNFTAssetName,
          ) == 1,
          list.indexed_foldr(
            lswInputs,
            True,
            fn(index, input, result) {
              //As all inputs must return True, if any of previous input returned False, then fail
              //The last input is not checked but will return its value at the end, so if False withdraw will fail
              expect result

              let lenderBondRefInput =
                safe_list_at(
                  self.reference_inputs,
                  safe_list_at(lenderBondRefInputsIndexes, index),
                )
              let minswapOrderOutput = safe_list_at(minswapOrderOutputs, index)
              expect InlineDatum(inputDatum) = input.output.datum
              //We expect only assets to convert, no lender bonds
              expect RepaymentDatumWithToken { ownerAsset, data, .. } =
                inputDatum
              expect claimedCollateralAsset: CollateralAsset = data
              //This works only for fungibles, not for NFTs
              expect Some(claimedAssetName) =
                claimedCollateralAsset.maybeAssetName
              let claimedAsset =
                Asset {
                  policyId: claimedCollateralAsset.policyId,
                  assetName: claimedAssetName,
                }
              let claimedAssetQuantity =
                quantity_of(
                  input.output.value,
                  claimedAsset.policyId,
                  claimedAssetName,
                )

              expect InlineDatum(lbDatum) = lenderBondRefInput.output.datum
              expect lenderBondDatum: LenderSmartWalletDatum = lbDatum

              let claimedAssetUnit =
                bytearray.concat(claimedAsset.policyId, claimedAsset.assetName)

              let principalAssetUnit =
                bytearray.concat(
                  lenderBondDatum.principalAsset.policyId,
                  lenderBondDatum.principalAsset.assetName,
                )

              let orderedAssetUnits =
                list.sort(
                  [claimedAssetUnit, principalAssetUnit],
                  bytearray.compare,
                )

              let sortedClaimedAssetAndPrincipalAssetUnits =
                bytearray.concat(
                  safe_list_at(orderedAssetUnits, 0),
                  safe_list_at(orderedAssetUnits, 1),
                )

              expect Some((lpAsset, lpABDirection)) =
                dict.get(
                  lpAssetForPoolAssetPairAndDirection,
                  sortedClaimedAssetAndPrincipalAssetUnits,
                )
              let botFee =
                lenderBondDatum.swappingFeePerMille * claimedAssetQuantity / 1000

              let orderType =
                minswap.SwapExactIn {
                  a_to_b_direction: lpABDirection,
                  swap_amount_option: minswap.SAOSpecificAmount {
                    swap_amount: claimedAssetQuantity - botFee,
                  },
                  minimum_receive: 1,
                  killable: True,
                }

              let inputDatumHash =
                crypto.blake2b_256(builtin.serialise_data(inputDatum))
              let conversionDatumHash =
                crypto.blake2b_256(
                  builtin.serialise_data(
                    RepaymentDatumWithToken {
                      inputOutputReference: OutputReference {
                        transaction_id: "",
                        output_index: 0,
                      },
                      action: constants.converted_to_liquidity_action,
                      data: claimedAsset,
                      ownerAsset,
                    },
                  ),
                )

              let expectedOrderDatum =
                InlineDatum(
                  minswap.OrderDatum {
                    canceller: lenderBondDatum.lenderAuth,
                    refund_receiver: input.output.address,
                    refund_receiver_datum: minswap.EODInlineDatum {
                      hash: inputDatumHash,
                    },
                    success_receiver: input.output.address,
                    success_receiver_datum: minswap.EODInlineDatum {
                      hash: conversionDatumHash,
                    },
                    lp_asset: lpAsset,
                    step: orderType,
                    max_batcher_fee: 700000,
                    expiry_setting_opt: None,
                  },
                )

              let correctOrderValue =
                if claimedAsset.policyId == "" {
                  quantity_of(
                    minswapOrderOutput.value,
                    claimedAsset.policyId,
                    claimedAsset.assetName,
                  ) == claimedAssetQuantity - botFee
                } else {
                  and {
                    quantity_of(
                      minswapOrderOutput.value,
                      claimedAsset.policyId,
                      claimedAsset.assetName,
                    ) == claimedAssetQuantity - botFee,
                    quantity_of(minswapOrderOutput.value, "", "") == 2800000,
                  }
                }

              and {
                //Lender bond input must have the corresponding lender bond NFT
                quantity_of(
                  lenderBondRefInput.output.value,
                  ownerAsset.policyId,
                  ownerAsset.assetName,
                ) > 0,
                //Order must have correct datum and value
                builtin.equals_data(
                  minswapOrderOutput.datum,
                  expectedOrderDatum,
                ),
                correctOrderValue,
                //Ensure the order output is sent to the correct address, considering CIP113
                if input.output.address.payment_credential == Script(
                  smartTokensSpendScriptHash,
                ) {
                  minswapOrderOutput.address == Address {
                    payment_credential: Script(smartTokensSpendScriptHash),
                    //TODO Should it be spendcredential of the lender?
                    stake_credential: lenderBondDatum.lenderStakeCredential,
                  }
                } else {
                  minswapOrderOutput.address == Address {
                    payment_credential: Script(minswapV2SpendScriptHash),
                    //TODO Should it be spendcredential of the lender?
                    stake_credential: lenderBondDatum.lenderStakeCredential,
                  }
                },
              }
            },
          ),
        }
      }
      CompoundLiquidity { lenderBondInputIndexes, compoundedPoolNewIds } -> {
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
        let (lenderBondInputs, compoundedAssetsInputs) =
          list.partition(
            lswInputs,
            fn(input) {
              expect InlineDatum(inputDatum) = input.output.datum
              if inputDatum is LenderSmartWalletDatum {
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
            Script(lenderSmartWalletSpendScriptHash),
            credential,
            smartTokensSpendScriptHash,
          )

        let totalAddedLiquidityForEachPoolManager =
          dict.to_pairs(
            list.indexed_foldr(
              compoundedAssetsInputs,
              dict.empty,
              fn(index, compoundedAssetInput, result) {
                expect InlineDatum(compoundedAssetInputDatum) =
                  compoundedAssetInput.output.datum
                //Expect the correct datum type
                expect RepaymentDatumWithToken { ownerAsset, data, .. } =
                  compoundedAssetInputDatum
                expect assetToCompound: CollateralAsset = data
                let lenderBondInput =
                  safe_list_at(
                    lenderBondInputs,
                    safe_list_at(lenderBondInputIndexes, index),
                  )
                expect InlineDatum(lenderBondInputDatum) =
                  lenderBondInput.output.datum
                expect parsedLenderBondInputDatum: LenderSmartWalletDatum =
                  lenderBondInputDatum

                let lenderBondOutput = safe_list_at(lenderBondOutputs, index)

                //The asset to compound must be the same as the principal asset of the lender bond
                expect
                  builtin.equals_data(
                    parsedLenderBondInputDatum.principalAsset,
                    assetToCompound,
                  )
                //The lenderBondInput must contain the lender bond NFT
                expect
                  quantity_of(
                    lenderBondInput.output.value,
                    lenderBondPolicyId,
                    ownerAsset.assetName,
                  ) == 1
                //Lender bond datum, value and address must be the same in input and output
                expect
                  builtin.equals_data(lenderBondOutput, lenderBondInput.output)
                let addedLiquidity =
                  quantity_of(
                    compoundedAssetInput.output.value,
                    parsedLenderBondInputDatum.principalAsset.policyId,
                    parsedLenderBondInputDatum.principalAsset.assetName,
                  )

                //For this poolManager, add the liquidity
                dict.insert_with(
                  result,
                  parsedLenderBondInputDatum.poolManagerId,
                  addedLiquidity,
                  fn(_k, a, b) { Some(a + b) },
                )
              },
            ),
          )
        and {
          //All pool managers in input must have been used for compounding
          list.length(poolManagerInputs) == list.length(
            totalAddedLiquidityForEachPoolManager,
          ),
          //No additional pools spent
          list.length(poolManagerInputs) == list.length(poolInputs),
          list.indexed_foldr(
            totalAddedLiquidityForEachPoolManager,
            True,
            fn(index, Pair(poolManagerId, addedLiquidity), result) {
              //As all inputs must return True, if any of previous input returned False, then fail
              //The last input is not checked but will return its value at the end, so if False withdraw will fail
              expect result
              let poolManagerInput = safe_list_at(poolManagerInputs, index)
              let poolManagerOutput = safe_list_at(poolManagerOutputs, index)
              //TODO Is the index ok to select input and output?
              let poolInput = safe_list_at(poolInputs, index)
              let poolOutput = safe_list_at(poolOutputs, index)

              expect InlineDatum(poolManager) = poolManagerInput.output.datum
              expect PoolSmartManagerDatum { poolId, poolOwnerAuth } =
                poolManager

              expect InlineDatum(oldDatum) = poolInput.output.datum
              expect PoolDatum { commonData, .. } = oldDatum

              let newPoolId = safe_list_at(compoundedPoolNewIds, index)
              //Replace old liquidity with new one and replace old pool nft with new one
              //TODO In case of custom token, is same ADA amount a problem?
              let expectedNewValue =
                poolInput.output.value
                  |> add(
                      commonData.principalAsset.policyId,
                      commonData.principalAsset.assetName,
                      addedLiquidity,
                    )
                  |> add(poolPolicyId, poolId, -1)
                  |> add(poolPolicyId, newPoolId, 1)
              and {
                //Input poolManager must contain the NFT specified in the lender bond datums
                quantity_of(
                  poolManagerInput.output.value,
                  poolManagerPolicyId,
                  poolManagerId,
                ) == 1,
                //Pool must be the one specified in the poolManager datum
                quantity_of(poolInput.output.value, poolPolicyId, poolId) == 1,
                //Pool output must be correct
                builtin.equals_data(poolInput.output.datum, poolOutput.datum),
                poolOutput.value == expectedNewValue,
                poolInput.output.address == poolOutput.address,
                //PoolManager must be same in input and output except for the poolId
                builtin.equals_data(
                  poolManagerInput.output.address,
                  poolManagerOutput.address,
                ),
                poolManagerInput.output.value == poolManagerOutput.value,
                poolManagerOutput.datum == InlineDatum(
                  PoolSmartManagerDatum { poolOwnerAuth, poolId: newPoolId },
                ),
              }
            },
          ),
        }
      }
    }
  }

  else(_) {
    fail
  }
}
