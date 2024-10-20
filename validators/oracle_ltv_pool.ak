use aiken/collection/list.{length}
use aiken/crypto.{sha2_256}
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Script}
use cardano/assets.{Value, flatten, quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{InlineDatum, Output, OutputReference, Transaction}
use types/datum.{ActiveDatum, Liquidation, PoolDatum}
use types/general.{Asset, CollateralAsset}
use types/redeemer.{
  Aggregated, Borrow, Cancel, Dedicated, OraclePriceFeed, PoolAction,
  PoolSpendRedeemer, PoolWithdrawRedeemer, Pooled,
}
use utils.{
  address_in_signatures, authorize_action, get_inputs_from_sc, get_outputs_to_sc,
  get_own_hash, is_output_to_sc, quantity_of_policy_id, retrieve_oracle_data,
  safe_list_at, token_b_needed_to_purchase_token_a, validate_oracle_ref_input,
  validity_range_within_an_hour,
}

//TODO In case of V2 Script as lender, there must be a dummy datum. In pool's datum there must be a Bool indicating if this is necessary
validator pool(
  borrowerTokenPolicyId: ByteArray,
  lenderTokenPolicyId: ByteArray,
  activeLoanScriptHash: ByteArray,
  adminAddress: Address,
) {
  spend(
    datumOpt: Option<PoolDatum>,
    redeemer: PoolSpendRedeemer,
    input: OutputReference,
    self: Transaction,
  ) {
    if datumOpt == None {
      address_in_signatures(self.extra_signatories, adminAddress)
    } else {
      when redeemer is {
        Cancel(auth) -> {
          expect Some(datum) = datumOpt
          and {
            datum.lenderAuthHash == auth.hash,
            authorize_action(
              auth,
              self.inputs,
              self.withdrawals,
              self.extra_signatories,
              self.mint,
            ),
          }
        }
        Borrow(withdrawIndex) -> {
          let ownScriptHash = get_own_hash(input, self.inputs)
          expect Some(withdrawScript) = list.at(self.withdrawals, withdrawIndex)
          when withdrawScript is {
            Pair(Script(scriptHash), _amnt) -> scriptHash == ownScriptHash
            _ -> False
          }
        }
      }
    }
  }

  withdraw(
    redeemer: PoolWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(ownScriptHash) = credential
    let scInputs = get_inputs_from_sc(self.inputs, ownScriptHash)
    //Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
    expect length(scInputs) == length(redeemer.actionForEachInput)

    list.indexed_foldr(
      scInputs,
      True,
      fn(index, input, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        let redeemerAction = safe_list_at(redeemer.actionForEachInput, index)
        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: PoolDatum = inputDatum
        let PoolAction {
          borrowerAddress,
          outputWithLenderTokenIndex,
          chosenCollateralIndex,
          chosenCollateralOracleInputIndex,
          wantedPrincipal,
        } = redeemerAction
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
            get_outputs_to_sc(self.outputs, activeLoanScriptHash),
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

        let basicChecks = and {
            wantedPrincipal > 0,
            remainingAmount >= 0,
            validity_range_within_an_hour(self),
            tokens_sent_to_both_parties(
              self.mint,
              outputWithLenderToken,
              borrowerTokenPolicyId,
              lenderTokenPolicyId,
              inputUtxoId,
              datum.lenderAddress,
            ),
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
              and {
                validate_oracle_ref_input(
                  oracleRefInput.output.value,
                  chosenCollateral,
                ),
                validate_output_to_active_with_oracle(
                  activeOutput,
                  activeLoanScriptHash,
                  datum,
                  chosenCollateral,
                  chosenCollateralIndex,
                  wantedPrincipal,
                  inputUtxoId,
                  end,
                  borrowerAddress,
                  oraclePriceFeed,
                ),
              }
            } else {
              validate_output_to_active_no_oracle(
                activeOutput,
                activeLoanScriptHash,
                datum,
                chosenCollateral,
                chosenCollateralIndex,
                wantedPrincipal,
                inputUtxoId,
                end,
                borrowerAddress,
              )
            },
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
              ),
            },
          },
        }
      },
    )
  }

  else(ctx: ScriptContext) {
    address_in_signatures(ctx.transaction.extra_signatories, adminAddress)
  }
}

fn tokens_sent_to_both_parties(
  mintedValue: Value,
  outputWithLenderToken: Output,
  borrowerTokenPolicyId: ByteArray,
  lenderTokenPolicyId: ByteArray,
  inputUtxoId: ByteArray,
  lenderAddress: Address,
) {
  and {
    quantity_of(mintedValue, borrowerTokenPolicyId, inputUtxoId) == 1,
    outputWithLenderToken.address == lenderAddress,
    quantity_of(outputWithLenderToken.value, lenderTokenPolicyId, inputUtxoId) == 1,
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
) {
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

  let toCorrectStaking =
    output.address.stake_credential == borrowerAddress.stake_credential
  let dosProtection = length(flatten(output.value)) <= 21
  and {
    toCorrectStaking,
    is_output_to_sc(output, activeLoanScriptHash),
    containsCorrectCollateral,
    isDatumCorrect,
    dosProtection,
  }
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
) {
  expect Some(ltv) = list.at(poolDatum.principalLTV, chosenCollateralIndex)
  expect Some(principalLTVDivider) =
    list.at(poolDatum.principalLTVDivider, chosenCollateralIndex)
  expect Some(ltvAsRational) = rational.new(ltv, principalLTVDivider)
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
      principalDivider: principalLTVDivider,
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

  let toCorrectStaking =
    output.address.stake_credential == borrowerAddress.stake_credential

  let dosProtection = length(flatten(output.value)) <= 21
  and {
    toCorrectStaking,
    is_output_to_sc(output, activeLoanScriptHash),
    containsCorrectCollateral,
    isDatumCorrect,
    dosProtection,
  }
}

//Expects remainingAmount > 0
fn validate_eventual_output_to_pool(
  output: Output,
  datum: PoolDatum,
  remainingAmount: Int,
  ownScriptHash: ByteArray,
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

  let toCorrectStaking =
    output.address.stake_credential == datum.lenderAddress.stake_credential

  and {
    is_output_to_sc(output, ownScriptHash),
    containsCorrectAmount,
    isDatumCorrect,
    dosProtection,
    toCorrectStaking,
  }
}
