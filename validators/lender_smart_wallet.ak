use aiken/builtin
use aiken/collection/dict
use aiken/collection/list.{length}
use aiken/crypto
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use aiken/option
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Script}
use cardano/assets.{PolicyId, Value, add, flatten, quantity_of, tokens}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, find_input,
}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/constants
use fluidtokens/finance.{
  get_needed_collateral_with_oracles, get_needed_collateral_without_oracles,
}
use fluidtokens/oracle.{retrieve_oracle_data}
use fluidtokens/types/general.{
  Asset, AuthorizationMethod, CollateralAsset, Liquidation,
}
use fluidtokens/types/lender_smart_wallet.{
  Cancel, ClaimLoans, CompoundLiquidity, ConvertToLiquidity,
  LenderSmartWalletDatum, LenderSmartWalletWithdrawRedeemer, Withdraw,
} as lsw
use fluidtokens/types/loan.{LoanDatum}
use fluidtokens/types/minswap_info.{MinswapV2Info}
use fluidtokens/types/minswap_v2_types as minswap
use fluidtokens/types/pool.{PoolDatum}
use fluidtokens/types/repayment.{
  RepaymentDatum, RepaymentDatumWithHash, RepaymentDatumWithToken,
  RepaymentMintRedeemer, RepaymentWithdrawRedeemer, WithdrawWithHash,
  WithdrawWithToken,
} as r
use fluidtokens/utils.{
  asset_names_number_of_policy_id, is_output_to_spend_validator,
  quantity_of_policy_id, safe_list_at, validity_range_within_an_hour,
}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator lenderSmartWallet(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  lenderSmartWalletSpendScriptHash: ByteArray,
  minswapV2SpendScriptAddress: Address,
  minswapV2InfoNFTPolicyId: ByteArray,
  minswapV2InfoNFTAssetName: ByteArray,
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

    let poolInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(poolSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )

    when redeemer.action is {
      //As we loop through the inputs we DO NOT need to ensure that the number of actions is equal to the number of inputs
      Cancel -> and {
          //Ensure we don't give accidental authorization to cancelling any pool
          list.length(poolInputs) == 0,
          list.foldr(
            lswInputs,
            True,
            fn(input, result) {
              //As all inputs must return True, if any of previous input returned False, then fail
              //The last input is not checked but will return its value at the end, so if False withdraw will fail
              expect result

              expect InlineDatum(inputDatum) = input.output.datum
              //TODO Can be optimized with builtins
              expect datum: LenderSmartWalletDatum = inputDatum
              authorize_action(
                create_auth(
                  datum.lenderAuth,
                  self.inputs,
                  self.withdrawals,
                  self.extra_signatories,
                  self.mint,
                ),
              )
            },
          ),
        }
      Withdraw { lenderBondOutputIndexes } -> and {
          //Ensure we don't give accidental authorization to cancelling any pool
          list.length(poolInputs) == 0,
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
          ),
        }

      ClaimLoans { loanIds } -> {
        let loanInputs =
          get_inputs_from_smart_credential(
            self.inputs,
            Script(loanSpendScriptHash),
            credential,
            smartTokensSpendScriptHash,
          )
        and {
          //Ensure we don't give accidental authorization to cancelling any pool
          list.length(poolInputs) == 0,
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

              let loanInput = safe_list_at(loanInputs, index)
              expect InlineDatum(inputLoanDatum) = loanInput.output.datum
              expect loanDatum: LoanDatum = inputLoanDatum

              //TODO Should this be using filtered outputs list?
              let claimedCollateralOutput = safe_list_at(self.outputs, index)
              //TODO Should this be using filtered outputs list?
              let lenderBondOutput = safe_list_at(self.outputs, index)

              expect InlineDatum(outputDatum) = claimedCollateralOutput.datum
              expect RepaymentDatumWithToken { ownerAsset, action, data, .. } =
                outputDatum
              expect claimedAsset: CollateralAsset = data

              let loanId = safe_list_at(loanIds, index)
              and {
                //TODO Do we even need to filter loans that are liquidated?
                //TODO Should we check that loan reedemer action == Claim?  
                //We don't check that input contains any specific lender bond as we know it's there
                //if the loan can be propery claimed. We just ensure it goes back here
                builtin.equals_data(input.output.datum, lenderBondOutput.datum),
                builtin.equals_data(input.output.value, lenderBondOutput.value),
                input.output.address == lenderBondOutput.address,
                builtin.equals_data(
                  loanInput.output.value,
                  add(claimedCollateralOutput.value, loanPolicyId, loanId, 1),
                ),
                ownerAsset.policyId == lenderBondPolicyId,
                ownerAsset.assetName == loanId,
                action == constants.claimed_collateral_action,
                claimedAsset == loanDatum.collateral,
                //TODO This is not CIP113 compatible
                claimedCollateralOutput.address == Address {
                  payment_credential: Script(lenderSmartWalletSpendScriptHash),
                  stake_credential: lenderBondDatum.lenderStakeCredential,
                },
              }
            },
          ),
        }
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
        and {
          //Ensure we don't give accidental authorization to cancelling any pool
          list.length(poolInputs) == 0,
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
              //TODO Should this be using filtered outputs list?
              let minswapOrderOutput = safe_list_at(self.outputs, index)
              expect InlineDatum(inputDatum) = input.output.datum
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

              //TODO This is not CIP113 compatible
              let thisAddress =
                Address {
                  payment_credential: Script(lenderSmartWalletSpendScriptHash),
                  stake_credential: lenderBondDatum.lenderStakeCredential,
                }

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
                    refund_receiver: thisAddress,
                    refund_receiver_datum: minswap.EODInlineDatum {
                      hash: inputDatumHash,
                    },
                    success_receiver: thisAddress,
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
                quantity_of(
                  lenderBondRefInput.output.value,
                  ownerAsset.policyId,
                  ownerAsset.assetName,
                ) > 0,
                builtin.equals_data(
                  minswapOrderOutput.datum,
                  expectedOrderDatum,
                ),
                correctOrderValue,
                //TODO This is not CIP113 compatible
                minswapOrderOutput.address == minswapV2SpendScriptAddress,
              }
            },
          ),
        }
      }
      CompoundLiquidity { lenderBondRefInputIndexes, compoundedPoolNewIds } -> {
        let totalAddedLiquidityForEachPool =
          list.indexed_foldr(
            lswInputs,
            dict.empty,
            fn(index, input, result) {
              expect InlineDatum(inputDatum) = input.output.datum
              expect RepaymentDatumWithToken { ownerAsset, action, .. } =
                inputDatum
              //Exclude any utxo that has collateral to liquidate
              expect action != constants.claimed_collateral_action
              let lenderBondRefInput =
                safe_list_at(
                  self.reference_inputs,
                  safe_list_at(lenderBondRefInputIndexes, index),
                )

              //The lenderBondRefInput must obviously contain the lender bond NFT
              expect
                quantity_of(
                  lenderBondRefInput.output.value,
                  lenderBondPolicyId,
                  ownerAsset.assetName,
                ) == 1

              expect InlineDatum(lenderBondDatum) =
                lenderBondRefInput.output.datum
              expect LenderSmartWalletDatum { poolId, principalAsset, .. } =
                lenderBondDatum

              let addedLiquidity =
                quantity_of(
                  input.output.value,
                  principalAsset.policyId,
                  principalAsset.assetName,
                )

              dict.insert_with(
                result,
                poolId,
                addedLiquidity,
                fn(_k, a, b) { Some(a + b) },
              )
            },
          )

        list.indexed_foldr(
          dict.to_pairs(totalAddedLiquidityForEachPool),
          True,
          fn(index, Pair(poolId, addedLiquidity), result) {
            //As all inputs must return True, if any of previous input returned False, then fail
            //The last input is not checked but will return its value at the end, so if False withdraw will fail
            expect result
            let poolInput = safe_list_at(poolInputs, index)
            //TODO Should this be using filtered outputs list?
            let poolOutput = safe_list_at(self.outputs, index)

            expect InlineDatum(oldDatum) = poolInput.output.datum
            expect PoolDatum { commonData, .. } = oldDatum
            let oldLiquidity =
              quantity_of(
                poolInput.output.value,
                commonData.principalAsset.policyId,
                commonData.principalAsset.assetName,
              )
            let newLiquidity = oldLiquidity + addedLiquidity
            //Replace old liquidity with new one and replace old pool nft to new one
            let expectedNewValue =
              poolInput.output.value
                |> add(
                    commonData.principalAsset.policyId,
                    commonData.principalAsset.assetName,
                    oldLiquidity * -(-1),
                  )
                |> add(
                    commonData.principalAsset.policyId,
                    commonData.principalAsset.assetName,
                    newLiquidity,
                  )
                |> add(poolPolicyId, poolId, -1)
                |> add(
                    poolPolicyId,
                    safe_list_at(compoundedPoolNewIds, index),
                    1,
                  )
            and {
              //We know the pool is a proper pool because in its value there's the old pool nft
              quantity_of(poolInput.output.value, poolPolicyId, poolId) == 1,
              builtin.equals_data(poolInput.output.datum, poolOutput.datum),
              poolOutput.value == expectedNewValue,
              poolInput.output.address == poolOutput.address,
            }
          },
        )
      }
    }
  }

  else(_) {
    fail
  }
}
