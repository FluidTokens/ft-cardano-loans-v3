use aiken/collection/list.{length}
use aiken/crypto.{sha2_256}
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Script}
use cardano/assets.{Value, flatten, quantity_of}
use cardano/transaction.{InlineDatum, Output, OutputReference, Transaction}
use types/datum.{ActiveDatum, Liquidation, LoanInfoDatum, PoolDatum}
use types/general.{Asset, CollateralAsset}
use types/redeemer.{
  Aggregated, Borrow, Cancel, Dedicated, OraclePriceFeed, PoolWithdrawRedeemer,
  Pooled,
}
use utils.{
  authorize_action, get_inputs_from_sc_or_delegated_to_sc,
  get_outputs_to_sc_or_delegated_to_sc, is_output_to_sc, quantity_of_policy_id,
  retrieve_oracle_data, safe_list_at, token_b_needed_to_purchase_token_a,
  validate_oracle_ref_input, validity_range_within_an_hour,
}

validator pool(configAsset: Asset) {
  withdraw(
    redeemer: PoolWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(ownScriptHash) = credential
    let scInputs =
      get_inputs_from_sc_or_delegated_to_sc(self.inputs, ownScriptHash)
    //Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
    expect length(scInputs) == length(redeemer.actionForEachInput)
    let config =
      utils.get_config(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configAsset.policyId,
        configAsset.assetName,
      )

    list.indexed_foldr(
      scInputs,
      True,
      fn(index, inputAndCIP113Control, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        let input = inputAndCIP113Control.1st
        let isCIP113 = inputAndCIP113Control.2nd
        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: PoolDatum = inputDatum
        let redeemerAction = safe_list_at(redeemer.actionForEachInput, index)

        when redeemerAction is {
          Cancel(auth) -> and {
              datum.lenderAuthHash == auth.hash,
              authorize_action(
                auth,
                self.inputs,
                self.withdrawals,
                self.extra_signatories,
                self.mint,
              ),
            }
          Borrow(
            borrowerAddress,
            outputWithLenderTokenIndex,
            chosenCollateralIndex,
            chosenCollateralOracleInputIndex,
            wantedPrincipal,
          ) -> {
            expect Finite(end) = self.validity_range.upper_bound.bound_type
            let inputUtxoId =
              sha2_256(
                bytearray.push(
                  input.output_reference.transaction_id,
                  input.output_reference.output_index,
                ),
              )
            let activeOutput =
              safe_list_at(
                get_outputs_to_sc_or_delegated_to_sc(
                  self.outputs,
                  config.activeLoanSpendScriptHash,
                  isCIP113,
                ),
                index,
              )
            let outputWithLenderToken =
              safe_list_at(self.outputs, outputWithLenderTokenIndex)
            let chosenCollateral =
              safe_list_at(datum.collateralOptions, chosenCollateralIndex)
            let remainingAmount =
              quantity_of(
                input.output.value,
                datum.commonData.principalAsset.policyId,
                datum.commonData.principalAsset.assetName,
              ) - wantedPrincipal

            let outputToActiveValidationResults =
              if datum.dynamicCollateralPrice {
                let oracleRefInput =
                  safe_list_at(
                    self.reference_inputs,
                    chosenCollateralOracleInputIndex,
                  )
                expect Some(oraclePriceFeed) =
                  retrieve_oracle_data(
                    oracleRefInput,
                    self.redeemers,
                    end,
                    chosenCollateral,
                  )
                expect
                  validate_oracle_ref_input(
                    oracleRefInput.output.value,
                    chosenCollateral,
                  ) == True
                validate_output_to_active_with_oracle(
                  activeOutput,
                  config.activeLoanSpendScriptHash,
                  datum,
                  chosenCollateral,
                  chosenCollateralIndex,
                  wantedPrincipal,
                  inputUtxoId,
                  end,
                  borrowerAddress,
                  oraclePriceFeed,
                  isCIP113,
                )
              } else {
                validate_output_to_active_no_oracle(
                  activeOutput,
                  config.activeLoanSpendScriptHash,
                  datum,
                  chosenCollateral,
                  chosenCollateralIndex,
                  wantedPrincipal,
                  inputUtxoId,
                  end,
                  borrowerAddress,
                  isCIP113,
                )
              }

            let basicChecks = and {
                wantedPrincipal > 0,
                remainingAmount >= 0,
                validity_range_within_an_hour(self),
                outputToActiveValidationResults.1st,
                tokens_sent_to_both_parties(
                  self.mint,
                  outputWithLenderToken,
                  config.borrowerTokenPolicyId,
                  config.lenderTokenPolicyId,
                  inputUtxoId,
                  datum.lenderAddress,
                  datum.lenderTokenOutputMustHaveLoanInfoDatum,
                  outputToActiveValidationResults.2nd,
                ),
              }
            and {
              basicChecks,
              or {
                remainingAmount == 0,
                and {
                  remainingAmount > 0,
                  validate_eventual_output_to_pool(
                    safe_list_at(self.outputs, index),
                    datum,
                    remainingAmount,
                    ownScriptHash,
                    isCIP113,
                  ),
                },
              },
            }
          }
        }
      },
    )
  }

  else(_) {
    fail
  }
}

fn tokens_sent_to_both_parties(
  mintedValue: Value,
  outputWithLenderToken: Output,
  borrowerTokenPolicyId: ByteArray,
  lenderTokenPolicyId: ByteArray,
  inputUtxoId: ByteArray,
  lenderAddress: Address,
  lenderTokenOutputMustHaveLoanInfoDatum: Bool,
  lenderBondOutputDatum: LoanInfoDatum,
) {
  and {
    quantity_of(mintedValue, borrowerTokenPolicyId, inputUtxoId) == 1,
    outputWithLenderToken.address == lenderAddress,
    quantity_of(outputWithLenderToken.value, lenderTokenPolicyId, inputUtxoId) == 1,
    or {
      lenderTokenOutputMustHaveLoanInfoDatum == False,
      outputWithLenderToken.datum == InlineDatum(lenderBondOutputDatum),
    },
    length(flatten(outputWithLenderToken.value)) <= 5,
  }
}

fn validate_output_to_active_no_oracle(
  output: Output,
  activeLoanScriptHash: ByteArray,
  poolDatum: PoolDatum,
  chosenCollateral: CollateralAsset,
  chosenCollateralIndex: Int,
  wantedPrincipal: Int,
  inputUtxoId: ByteArray,
  end: Int,
  borrowerAddress: Address,
  isCIP113: Bool,
) -> (Bool, LoanInfoDatum) {
  expect Some(singleRequiredAmount) =
    list.at(poolDatum.principalLTV, chosenCollateralIndex)
  expect Some(principalDivider) =
    list.at(poolDatum.principalLTVDivider, chosenCollateralIndex)
  expect Some(singleRequiredAmountAsRational) =
    rational.new(singleRequiredAmount, principalDivider)
  expect Some(minNeededCollateralAmountAsRational) =
    rational.div(
      rational.from_int(wantedPrincipal),
      singleRequiredAmountAsRational,
    )
  let minNeededCollateralAmount =
    rational.ceil(minNeededCollateralAmountAsRational)

  let containsCorrectCollateral =
    when chosenCollateral.maybeAssetName is {
      Some(chosenCollateralAssetName) ->
        quantity_of(
          output.value,
          chosenCollateral.policyId,
          chosenCollateralAssetName,
        ) >= minNeededCollateralAmount
      None ->
        quantity_of_policy_id(output.value, chosenCollateral.policyId) >= minNeededCollateralAmount
    }

  expect InlineDatum(outputDatum) = output.datum
  expect parsedDatum: ActiveDatum = outputDatum
  let newDatum =
    ActiveDatum {
      commonData: poolDatum.commonData,
      borrowerAssetName: inputUtxoId,
      lenderAssetName: inputUtxoId,
      collateral: chosenCollateral,
      principalAmount: wantedPrincipal,
      principalDivider,
      lendDate: end,
      repaidInstallments: 0,
      doneRecasts: 0,
    }

  let isLiquidationCorrectlySet =
    when newDatum.commonData.liquidationMode is {
      Liquidation { .. } -> newDatum.collateral.maybeOracleTokenAsset != None
      _ -> True
    }
  let isDatumCorrect = parsedDatum == newDatum && isLiquidationCorrectlySet

  let toCorrectStaking = or {
      isCIP113 == True,
      output.address.stake_credential == borrowerAddress.stake_credential,
    }
  let dosProtection = length(flatten(output.value)) <= 21
  (and {
      toCorrectStaking,
      is_output_to_sc(output, activeLoanScriptHash),
      containsCorrectCollateral,
      isDatumCorrect,
      dosProtection,
    }, newDatum)
}

fn validate_output_to_active_with_oracle(
  output: Output,
  activeLoanScriptHash: ByteArray,
  poolDatum: PoolDatum,
  chosenCollateral: CollateralAsset,
  chosenCollateralIndex: Int,
  wantedPrincipal: Int,
  inputUtxoId: ByteArray,
  end: Int,
  borrowerAddress: Address,
  oraclePriceFeed: OraclePriceFeed,
  isCIP113: Bool,
) -> (Bool, LoanInfoDatum) {
  expect Some(ltv) = list.at(poolDatum.principalLTV, chosenCollateralIndex)
  expect Some(ltvDivider) =
    list.at(poolDatum.principalLTVDivider, chosenCollateralIndex)
  expect Some(ltvAsRational) = rational.new(ltv, ltvDivider)
  expect Some(minNeededCollateralInPrincipalCurrency) =
    rational.div(rational.from_int(wantedPrincipal), ltvAsRational)

  let minNeededCollateralAmount =
    when oraclePriceFeed is {
      Aggregated(aggregated_data) -> {
        expect Some(tokenPrice) =
          rational.new(
            aggregated_data.token_price_in_lovelaces,
            aggregated_data.denominator,
          )

        expect Some(minNeededCollateralAmountAsRational) =
          rational.div(minNeededCollateralInPrincipalCurrency, tokenPrice)
        rational.ceil(minNeededCollateralAmountAsRational)
      }
      Pooled(pooled_data) ->
        token_b_needed_to_purchase_token_a(
          minNeededCollateralInPrincipalCurrency,
          pooled_data.token_a_amount,
          pooled_data.token_b_amount,
        )
      Dedicated(dedicated_data) -> {
        expect Some(tokenPrice) =
          rational.new(dedicated_data.token_price, dedicated_data.denominator)

        expect Greater =
          rational.compare(tokenPrice, minNeededCollateralInPrincipalCurrency)
        1
      }
    }
  let containsCorrectCollateral =
    when chosenCollateral.maybeAssetName is {
      Some(chosenCollateralAssetName) ->
        quantity_of(
          output.value,
          chosenCollateral.policyId,
          chosenCollateralAssetName,
        ) >= minNeededCollateralAmount
      None ->
        quantity_of_policy_id(output.value, chosenCollateral.policyId) >= minNeededCollateralAmount
    }

  expect InlineDatum(outputDatum) = output.datum
  expect parsedDatum: ActiveDatum = outputDatum
  let newDatum =
    ActiveDatum {
      commonData: poolDatum.commonData,
      borrowerAssetName: inputUtxoId,
      lenderAssetName: inputUtxoId,
      collateral: chosenCollateral,
      principalAmount: wantedPrincipal,
      principalDivider: ltvDivider,
      lendDate: end,
      repaidInstallments: 0,
      doneRecasts: 0,
    }

  let isLiquidationCorrectlySet =
    when newDatum.commonData.liquidationMode is {
      Liquidation { .. } -> newDatum.collateral.maybeOracleTokenAsset != None
      _ -> True
    }

  let isDatumCorrect = parsedDatum == newDatum && isLiquidationCorrectlySet

  let toCorrectStaking = or {
      isCIP113 == True,
      output.address.stake_credential == borrowerAddress.stake_credential,
    }

  let dosProtection = length(flatten(output.value)) <= 21
  (and {
      toCorrectStaking,
      is_output_to_sc(output, activeLoanScriptHash),
      containsCorrectCollateral,
      isDatumCorrect,
      dosProtection,
    }, newDatum)
}

//Expects remainingAmount > 0
fn validate_eventual_output_to_pool(
  output: Output,
  datum: PoolDatum,
  remainingAmount: Int,
  ownScriptHash: ByteArray,
  isCIP113: Bool,
) {
  expect InlineDatum(outputDatum) = output.datum
  expect parsedDatum: PoolDatum = outputDatum

  let containsCorrectAmount =
    quantity_of(
      output.value,
      datum.commonData.principalAsset.policyId,
      datum.commonData.principalAsset.assetName,
    ) == remainingAmount

  let isDatumCorrect = parsedDatum == datum

  let dosProtection = length(flatten(output.value)) <= 3

  let toCorrectStaking = or {
      isCIP113 == True,
      output.address.stake_credential == datum.lenderAddress.stake_credential,
    }

  and {
    is_output_to_sc(output, ownScriptHash),
    containsCorrectAmount,
    isDatumCorrect,
    dosProtection,
    toCorrectStaking,
  }
}
