use aiken/builtin
use aiken/collection/dict
use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use aiken/option
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Script}
use cardano/assets.{PolicyId, Value, add, flatten, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Input, Output, Transaction, find_input}
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
) {
  withdraw(
    redeemer: LenderSmartWalletWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(lswPolicyId) = credential
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

      ClaimLoans {
        lenderBondOutputIndexes,
        claimedCollateralOutputIndexes,
        loanIds,
      } -> {
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

              let lenderBondOutput =
                safe_list_at(
                  self.outputs,
                  safe_list_at(lenderBondOutputIndexes, index),
                )
              and {
                builtin.equals_data(input.output.datum, lenderBondOutput.datum),
                builtin.equals_data(input.output.value, lenderBondOutput.value),
                input.output.address == lenderBondOutput.address,
              }
            },
          ),
          list.indexed_foldr(
            loanInputs,
            True,
            fn(index, input, result) {
              //As all inputs must return True, if any of previous input returned False, then fail
              //The last input is not checked but will return its value at the end, so if False withdraw will fail
              expect result

              expect InlineDatum(inputDatum) = input.output.datum
              expect loanDatum: LoanDatum = inputDatum

              let claimedCollateralOutput =
                safe_list_at(
                  self.outputs,
                  safe_list_at(claimedCollateralOutputIndexes, index),
                )

              expect InlineDatum(outputDatum) = claimedCollateralOutput.datum
              expect RepaymentDatumWithToken { ownerAsset, action, .. } =
                outputDatum

              let loanId = safe_list_at(loanIds, index)
              and {
                validate_liquidated_loan(loanDatum),
                //TODO Should we check that loan action == Claim?         
                validate_claimed_collateral_output(
                  input.output.value,
                  ownerAsset,
                  action,
                  claimedCollateralOutput.value,
                  claimedCollateralOutput.address,
                  lenderSmartWalletSpendScriptHash,
                  lenderBondPolicyId,
                  loanPolicyId,
                  loanId,
                ),
              }
            },
          ),
        }
      }
      ConvertToLiquidity {
        lenderBondRefInputsIndexes,
        minswapOrderOutputIndexes,
      } -> and {
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

              let lenderBondRefInput =
                safe_list_at(
                  self.reference_inputs,
                  safe_list_at(lenderBondRefInputsIndexes, index),
                )

              let minswapOrderOutput =
                safe_list_at(
                  self.outputs,
                  safe_list_at(minswapOrderOutputIndexes, index),
                )

              //TODO
              let correctOrderDatum = False
              let correctOrderValue = False
              let correctOrderAddress = False

              and {
                correctOrderDatum,
                correctOrderValue,
                correctOrderAddress,
              }
            },
          ),
        }
      CompoundLiquidity {
        lenderBondRefInputIndexes,
        compoundedPoolInputsIndexes,
        compoundedPoolOutputsIndexes,
        compoundedPoolNewIds,
      } -> {
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
            let poolInput =
              safe_list_at(
                self.inputs,
                safe_list_at(compoundedPoolInputsIndexes, index),
              )
            let poolOutput =
              safe_list_at(
                self.outputs,
                safe_list_at(compoundedPoolOutputsIndexes, index),
              )

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
              quantity_of(poolInput.output.value, poolPolicyId, poolId) == 1,
              builtin.equals_data(poolInput.output.datum, poolOutput.datum),
              poolOutput.value == expectedNewValue,
              //TODO This is not CIP113 compatible
              poolInput.output.address.payment_credential == Script(
                poolSpendScriptHash,
              ),
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

fn validate_liquidated_loan(loanDatum: LoanDatum) {
  //TODO Do we even need to filter loans that are liquidated?
  True
}

fn validate_claimed_collateral_output(
  loanValue: Value,
  outputOwnerAsset: Asset,
  action: ByteArray,
  outputValue: Value,
  outputAddress: Address,
  lenderSmartWalletSpendScriptHash: ByteArray,
  lenderBondPolicyId: ByteArray,
  loanPolicyId: ByteArray,
  loanId: ByteArray,
) {
  and {
    builtin.equals_data(loanValue, add(outputValue, loanPolicyId, loanId, 1)),
    outputOwnerAsset.policyId == lenderBondPolicyId,
    outputOwnerAsset.assetName == loanId,
    action == constants.claimed_collateral_action,
    //TODO This is not CIP113 compatible
    outputAddress.payment_credential == Script(lenderSmartWalletSpendScriptHash),
  }
}
