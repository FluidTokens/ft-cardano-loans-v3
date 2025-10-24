use aiken/builtin
use aiken/collection/list
use aiken/crypto
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Inline, Script}
use cardano/assets.{quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use fluidtokens/constants
use fluidtokens/finance
use fluidtokens/types/general.{Asset, CollateralAsset}
use fluidtokens/types/lender_smart_manager.{
  LSMLiquidateAndConvertActionWithdrawRedeemer, LenderSmartManagerDatum,
} as lsm
use fluidtokens/types/loan.{LoanDatum} as l
use fluidtokens/types/minswap_v2_types as minswap
use fluidtokens/types/minswap_v2_types.{PoolDatum}
use fluidtokens/types/repayment.{RepaymentDatumWithToken} as r
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator actionValidator(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  lenderSmartManagerSpendScriptHash: ByteArray,
  loanWithdrawScriptHash: ByteArray,
  minswapPoolPolicyId: ByteArray,
  minswapPoolSpendScriptHash: ByteArray,
  minswapPoolWithdrawScriptHash: ByteArray,
  minswapOrderSpendScriptHash: ByteArray,
  minswapOrderWithdrawScriptHash: ByteArray,
  minswapV2DefaultTradingFeeDenominator: Int,
  maxAllowedSlippage: Int,
) {
  withdraw(
    redeemer: LSMLiquidateAndConvertActionWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Finite(validTo) = self.validity_range.upper_bound.bound_type
    let config =
      utils.get_config_as_data_list(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let smartTokensSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 0))
    let loanSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 10))
    let loanPolicyId = builtin.un_b_data(utils.safe_list_at(config, 6))
    let lenderBondPolicyId = builtin.un_b_data(utils.safe_list_at(config, 5))
    let lsmInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(lenderSmartManagerSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )
    let loanInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(loanSpendScriptHash),
        Script(loanWithdrawScriptHash),
        smartTokensSpendScriptHash,
      )
    let minswapPoolRefInputs =
      get_inputs_from_smart_credential(
        self.reference_inputs,
        Script(minswapPoolSpendScriptHash),
        Script(minswapPoolWithdrawScriptHash),
        smartTokensSpendScriptHash,
      )
    let lenderBondInputs = lsmInputs
    let lenderBondOutputs =
      get_outputs_to_smart_credential(
        self.outputs,
        Script(lenderSmartManagerSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )
    //TODO Is credential correct here?
    let minswapOrderOutputs =
      get_outputs_to_smart_credential(
        self.outputs,
        Script(minswapOrderSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )

    let liquidatedCollateralOutputsAreCorrect =
      list.indexed_foldr(
        loanInputs,
        False,
        fn(index, loanInput, result) {
          //As all inputs must return True, if any of previous input returned False, then fail
          //The last input is not checked but will return its value at the end, so if False withdraw will fail
          expect result
          let lenderBondAssetName =
            safe_list_at(redeemer.lenderBondAssetNames, index)
          let lenderBondIndex =
            safe_list_at(redeemer.lenderBondInputIndexes, index)
          let lenderBondInput = safe_list_at(lenderBondInputs, lenderBondIndex)
          let minswapPoolRefInput =
            safe_list_at(
              minswapPoolRefInputs,
              safe_list_at(redeemer.minswapRefInputindexes, index),
            )
          let minswapPoolAssetName =
            safe_list_at(redeemer.minswapPoolAssetNames, index)
          let lenderBondOutput =
            safe_list_at(lenderBondOutputs, lenderBondIndex)
          let minswapOrderOutput = safe_list_at(minswapOrderOutputs, index)

          expect InlineDatum(loanInputDatum) = loanInput.output.datum
          expect LoanDatum {
            collateral,
            principalAsset,
            principalAmount,
            interestRate,
            totalInstallments,
            repaidInstallments,
            installmentPeriod,
            initialGracePeriod,
            lendDate,
            repaymentMode,
            ..
          } = loanInputDatum
          expect InlineDatum(inputLenderBondDatum) =
            lenderBondInput.output.datum
          expect LenderSmartManagerDatum {
            shouldLiquidationConvertToPrincipal,
            liquidationFeePerMille,
            lenderAuth,
            lenderStakeCredential,
            ..
          } = inputLenderBondDatum
          let collateralPolicyId = collateral.policyId
          expect Some(collateralAssetName) = collateral.maybeAssetName
          let loanCollateralAmount =
            quantity_of(
              loanInput.output.value,
              collateralPolicyId,
              collateralAssetName,
            )
          let collateralAsset =
            Asset {
              policyId: collateralPolicyId,
              assetName: collateralAssetName,
            }
          let collateralAssetUnit =
            bytearray.concat(collateralPolicyId, collateralAssetName)

          let principalAssetUnit =
            bytearray.concat(principalAsset.policyId, principalAsset.assetName)

          expect InlineDatum(minswapPoolRefInputDatum) =
            minswapPoolRefInput.output.datum
          expect PoolDatum {
            asset_a,
            asset_b,
            reserve_a,
            reserve_b,
            base_fee_a_numerator,
            base_fee_b_numerator,
            ..
          } = minswapPoolRefInputDatum

          let orderedAssetUnits =
            list.sort(
              [collateralAssetUnit, principalAssetUnit],
              bytearray.compare,
            )

          let lpAssetName =
            get_minswap_lp_asset_name(
              safe_list_at(orderedAssetUnits, 0),
              safe_list_at(orderedAssetUnits, 1),
            )

          let isCollateralAssetA = asset_a == collateralAsset
          let lpABDirection =
            if isCollateralAssetA {
              True
            } else {
              False
            }
          let tradingFeeNumerator =
            if isCollateralAssetA {
              base_fee_a_numerator
            } else {
              base_fee_b_numerator
            }

          let liquidationFee =
            loanCollateralAmount * liquidationFeePerMille / 1000
          let swappableCollateralAmount = loanCollateralAmount - liquidationFee

          let ownerAsset =
            Asset {
              policyId: lenderBondPolicyId,
              assetName: lenderBondAssetName,
            }

          let orderType =
            minswap.SwapExactIn {
              a_to_b_direction: lpABDirection,
              swap_amount_option: minswap.SAOSpecificAmount {
                swap_amount: swappableCollateralAmount,
              },
              minimum_receive: 1,
              killable: True,
            }

          let inputDatumHash =
            crypto.blake2b_256(builtin.serialise_data(loanInput))
          let conversionDatumHash =
            crypto.blake2b_256(
              builtin.serialise_data(
                RepaymentDatumWithToken {
                  inputOutputReference: OutputReference {
                    transaction_id: "",
                    output_index: 0,
                  },
                  action: constants.converted_to_liquidity_action,
                  data: collateralAsset,
                  ownerAsset,
                },
              ),
            )

          let expectedOrderDatum =
            InlineDatum(
              minswap.OrderDatum {
                canceller: lenderAuth,
                refund_receiver: lenderBondInput.output.address,
                refund_receiver_datum: minswap.EODInlineDatum {
                  hash: inputDatumHash,
                },
                success_receiver: lenderBondInput.output.address,
                success_receiver_datum: minswap.EODInlineDatum {
                  hash: conversionDatumHash,
                },
                lp_asset: Asset {
                  policyId: minswapPoolPolicyId,
                  assetName: lpAssetName,
                },
                step: orderType,
                max_batcher_fee: 700000,
                expiry_setting_opt: None,
              },
            )

          let correctOrderValue =
            if collateralPolicyId == "" {
              quantity_of(
                minswapOrderOutput.value,
                collateralPolicyId,
                collateralAssetName,
              ) == swappableCollateralAmount
            } else {
              and {
                quantity_of(
                  minswapOrderOutput.value,
                  collateralPolicyId,
                  collateralAssetName,
                ) == swappableCollateralAmount,
                quantity_of(minswapOrderOutput.value, "", "") == 2800000,
              }
            }
          let reserveCollateral =
            if isCollateralAssetA {
              reserve_a
            } else {
              reserve_b
            }
          let reservePrincipal =
            if isCollateralAssetA {
              reserve_b
            } else {
              reserve_a
            }

          //Minswap v2 formula for amount out
          let diff = minswapV2DefaultTradingFeeDenominator - tradingFeeNumerator
          let inWithFee = diff * swappableCollateralAmount
          let numerator = inWithFee * reservePrincipal
          let denominator =
            minswapV2DefaultTradingFeeDenominator * reserveCollateral + inWithFee
          expect Some(amountOut) = rational.new(numerator, denominator)

          expect Some(collateralPriceIn) =
            rational.new(reserveCollateral, reservePrincipal)
          expect Some(collateralPriceOut) =
            rational.div(
              rational.sub(rational.from_int(reservePrincipal), amountOut),
              rational.from_int(reserveCollateral + swappableCollateralAmount),
            )

          and {
            //Lender bond must allow conversion to principal
            shouldLiquidationConvertToPrincipal,
            //Loan NFT AssetName must be same of lender bond
            quantity_of(
              loanInput.output.value,
              loanPolicyId,
              lenderBondAssetName,
            ) == 1,
            //Lender bond must be present in input
            quantity_of(
              lenderBondInput.output.value,
              lenderBondPolicyId,
              lenderBondAssetName,
            ) == 1,
            //Minswap LP token must be present in minswap pool reference input
            quantity_of(
              minswapPoolRefInput.output.value,
              minswapPoolPolicyId,
              minswapPoolAssetName,
            ) == 1,
            //Ensure the minswap pool is for the correct assets
            //TODO We need to order them correctly, what's the sorting logic of minswap?
            if isCollateralAssetA {
              asset_a == collateralAsset && asset_b == principalAsset
            } else {
              asset_a == principalAsset && asset_b == collateralAsset
            },
            //Order covers the minimum required amount
            rational.round(amountOut) >= finance.get_remaining_debt(
              repaymentMode,
              rational.from_int(principalAmount),
              rational.from_int(interestRate),
              totalInstallments,
              repaidInstallments,
              installmentPeriod,
              initialGracePeriod,
              validTo - lendDate,
            ),
            //Ensure that slippage is within acceptable limit
            check_slippage_after_swap(
              collateralPriceIn,
              collateralPriceOut,
              maxAllowedSlippage,
            ),
            //Output with lender bond must be the same as input
            builtin.equals_data(lenderBondInput.output, lenderBondOutput),
            //TODO Works only for full liquidations
            //Order must have correct datum and value
            builtin.equals_data(minswapOrderOutput.datum, expectedOrderDatum),
            correctOrderValue,
            //Ensure the order output is sent to the correct address, considering CIP113
            if loanInput.output.address.payment_credential == Script(
              smartTokensSpendScriptHash,
            ) {
              minswapOrderOutput.address == Address {
                payment_credential: Script(smartTokensSpendScriptHash),
                stake_credential: Some(
                  Inline(Script(minswapOrderWithdrawScriptHash)),
                ),
              }
            } else {
              minswapOrderOutput.address == Address {
                payment_credential: Script(minswapOrderSpendScriptHash),
                stake_credential: lenderStakeCredential,
              }
            },
          }
        },
      )

    and {
      //No additional lender bonds should be spent
      list.length(loanInputs) == list.length(lenderBondInputs),
      liquidatedCollateralOutputsAreCorrect,
    }
  }

  else(_) {
    fail
  }
}

fn check_slippage_after_swap(price_x_final, price_x_init, maxAllowedSlippage) {
  //slippage = price_x_final / price_x_init - 1.0
  expect Some(priceRatio) = rational.div(price_x_final, price_x_init)
  let slippage = rational.sub(priceRatio, rational.from_int(1))
  rational.compare(
    rational.abs(slippage),
    rational.from_int(maxAllowedSlippage),
  ) == Less
}

pub fn get_minswap_lp_asset_name(
  asset_a_unit: ByteArray,
  asset_b_unit: ByteArray,
) -> ByteArray {
  let asset_a_ident = crypto.sha3_256(asset_a_unit)
  let asset_b_ident = crypto.sha3_256(asset_b_unit)
  let pair_ident = bytearray.concat(asset_a_ident, asset_b_ident)
  crypto.sha3_256(pair_ident)
}
// test test_prices() {
//   let reserveCollateral = 100000000
//   let reservePrincipal = 200000000
//   let tradingFeeNumerator = 30
//   let minswapV2DefaultTradingFeeDenominator = 10000
//   let swappableCollateralAmount = 100000

//   let expectedCollateralPriceIn = rational.from_int(2)
//   let expectedCollateralPriceOut = rational.from_int(1)

//   //Minswap v2 formula for amount out
//   let diff = minswapV2DefaultTradingFeeDenominator - tradingFeeNumerator
//   let inWithFee = diff * swappableCollateralAmount
//   let numerator = inWithFee * reservePrincipal
//   let denominator =
//     minswapV2DefaultTradingFeeDenominator * reserveCollateral + inWithFee
//   expect Some(amountOut) = rational.new(numerator, denominator)

//   expect Some(collateralPriceIn) =
//     rational.new(reserveCollateral, reservePrincipal)
//   expect Some(collateralPriceOut) =
//     rational.div(
//       rational.sub(rational.from_int(reservePrincipal), amountOut),
//       rational.from_int(reserveCollateral + swappableCollateralAmount),
//     )

//   trace @"amountOut": amountOut
//   trace @"collateralPriceIn": collateralPriceIn
//   trace @"collateralPriceOut": collateralPriceOut

//   collateralPriceIn == expectedCollateralPriceIn && collateralPriceOut == expectedCollateralPriceOut
// }
