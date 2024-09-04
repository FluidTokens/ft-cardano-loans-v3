use aiken/bytearray
use aiken/dict
use aiken/hash.{sha2_256}
use aiken/interval.{Finite, Interval}
use aiken/list.{length}
use aiken/time.{PosixTime}
use aiken/transaction.{InlineDatum, Output, ScriptContext, Spend, Transaction}
use aiken/transaction/credential.{Address}
use aiken/transaction/value.{
  AssetName, Value, flatten, quantity_of, to_dict, without_lovelace,
}
use types/datum.{ActiveDatum, OracleLTVPoolDatum}
use types/general.{Asset, CollateralAsset}
use types/redeemer.{Accept, Cancel, OracleLTVPoolRedeemer, OraclePriceFeed}
use utils.{
  get_inputs_from_sc, get_outputs_to_sc, get_own_hash, is_output_to_sc,
  must_be_signed_by, retrieve_oracle_data, tokens_sent_to_lender_and_borrower,
  validity_range_within_an_hour,
}

validator(
  borrowerTokenPolicyId: ByteArray,
  lenderTokenPolicyId: ByteArray,
  activeLoanScriptHash: ByteArray,
) {
  fn validate(
    datum: OracleLTVPoolDatum,
    redeemer: OracleLTVPoolRedeemer,
    ctx: ScriptContext,
  ) -> Bool {
    let ScriptContext {
      transaction: Transaction {
        validity_range,
        inputs,
        outputs,
        redeemers,
        reference_inputs,
        ..
      },
      purpose,
    } = ctx
    let ownScriptHash = get_own_hash(purpose, inputs)
    when purpose is {
      Spend(currentInput) ->
        when redeemer is {
          Cancel -> must_be_signed_by(ctx.transaction, datum.lenderAddress)
          Accept(
            currentRequestInputIndex,
            outputWithBorrowerTokenIndex,
            outputWithLenderTokenIndex,
            chosenCollateral,
            chosenCollateralOracleInputIndex,
            wantedPrincipal,
          ) -> {
            let inputUtxoId =
              sha2_256(
                bytearray.push(
                  currentInput.transaction_id.hash,
                  currentInput.output_index,
                ),
              )
            expect Some(actualRequestInput) =
              list.at(
                get_inputs_from_sc(inputs, ownScriptHash),
                currentRequestInputIndex,
              )
            expect Some(activeOutput) =
              list.at(
                get_outputs_to_sc(outputs, activeLoanScriptHash),
                currentRequestInputIndex,
              )
            expect Some(outputWithBorrowerToken) =
              list.at(outputs, outputWithBorrowerTokenIndex)
            expect Some(outputWithLenderToken) =
              list.at(outputs, outputWithLenderTokenIndex)
            expect Finite(end) = validity_range.upper_bound.bound_type
            let remainingAmount =
              quantity_of(
                actualRequestInput.output.value,
                datum.poolAsset.policyId,
                datum.poolAsset.assetName,
              ) - wantedPrincipal

            let valid_chosen_collateral =
              list.has(datum.collateralOptions, chosenCollateral)

            let basicChecks = and {
                currentInput == actualRequestInput.output_reference,
                wantedPrincipal > 0,
                remainingAmount >= 0,
                validity_range_within_an_hour(ctx.transaction),
                valid_chosen_collateral,
                tokens_sent_to_both_parties(
                  outputWithBorrowerToken,
                  outputWithLenderToken,
                  borrowerTokenPolicyId,
                  lenderTokenPolicyId,
                  inputUtxoId,
                  datum.lenderAddress,
                ),
                if chosenCollateralOracleInputIndex >= 0 {
                  expect Some(oracleRefInput) =
                    list.at(reference_inputs, chosenCollateralOracleInputIndex)
                  expect Some(oraclePriceFeed) =
                    retrieve_oracle_data(oracleRefInput, redeemers, end)
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
                      wantedPrincipal,
                      inputUtxoId,
                      end,
                      oraclePriceFeed,
                    ),
                  }
                } else {
                  validate_output_to_active(
                    activeOutput,
                    activeLoanScriptHash,
                    datum,
                    chosenCollateral,
                    wantedPrincipal,
                    inputUtxoId,
                    end,
                  )
                },
              }
            and {
              basicChecks,
              when remainingAmount is {
                0 -> True
                amount if amount > 0 ->
                  validate_eventual_output_to_pool(
                    activeOutput,
                    ownScriptHash,
                    datum,
                    remainingAmount,
                  )
                _ -> False
              },
            }
          }
        }
    }
  }
}

fn validate_oracle_ref_input(
  oracleInputValue: Value,
  chosenCollateral: CollateralAsset,
) {
  expect Some(oracleToken) = chosenCollateral.oracleTokenAsset
  quantity_of(oracleInputValue, oracleToken.policyId, oracleToken.assetName) > 0
}

fn tokens_sent_to_both_parties(
  outputWithBorrowerToken: Output,
  outputWithLenderToken: Output,
  borrowerTokenPolicyId: ByteArray,
  lenderTokenPolicyId: ByteArray,
  inputUtxoId: ByteArray,
  lenderAddress: Address,
) {
  and {
    outputWithLenderToken.address == lenderAddress,
    quantity_of(
      outputWithBorrowerToken.value,
      borrowerTokenPolicyId,
      inputUtxoId,
    ) == 1,
    quantity_of(outputWithLenderToken.value, lenderTokenPolicyId, inputUtxoId) == 1,
    length(flatten(outputWithLenderToken.value)) <= 5,
  }
}

fn validate_output_to_active(
  output: Output,
  activeLoanScriptHash: ByteArray,
  poolDatum: OracleLTVPoolDatum,
  chosenCollateral: CollateralAsset,
  wantedPrincipal: Int,
  inputUtxoId: ByteArray,
  end: PosixTime,
) {
  expect InlineDatum(outputDatum) = output.datum
  expect parsedDatum: ActiveDatum = outputDatum

  let containsCorrectCollateral = TODO

  let newDatum =
    ActiveFutureDatum {
      futureData: datum.futureData,
      shortUserBondAssetName: bondAssetName,
      longUserBondAssetName: bondAssetName,
      futuresNumber: wantedFuturesNumber,
      startDate: end,
    }

  let isDatumCorrect = parsedDatum == newDatum

  let dosProtection = length(flatten(output.value)) <= 3
  and {
    //TODO Anything to enforce regarding stake credentials?
    is_output_to_sc(output, activeFutureScriptHash),
    containsCorrectCollateral,
    isDatumCorrect,
    dosProtection,
  }
}

fn validate_output_to_active_with_oracle(
  output: Output,
  activeLoanScriptHash: ByteArray,
  poolDatum: OracleLTVPoolDatum,
  chosenCollateral: CollateralAsset,
  wantedPrincipal: Int,
  inputUtxoId: ByteArray,
  end: PosixTime,
  oraclePriceFeed: OraclePriceFeed,
) {
  expect InlineDatum(outputDatum) = output.datum
  expect parsedDatum: ActiveDatum = outputDatum

  let expectedCollateralAmount =
    when loan_tokens_price is {
      Aggregated(aggregated_data) -> {
        expect Some(token_price) =
          rational.new(
            aggregated_data.token_price_in_lovelaces,
            aggregated_data.denominator,
          )

        amount_to_repay
          |> rational.mul(token_price)
          |> rational.truncate
      }
      Pooled(pooled_data) ->
        finance.token_b_needed_to_purchase_token_a(
          amount_to_repay,
          pooled_data.token_a_amount,
          pooled_data.token_b_amount,
        )
      Dedicated(dedicated_data) -> TODO
    }
  let containsCorrectCollateral =
    quantity_of(
      output.value,
      chosenCollateral.policyId,
      chosenCollateral.assetName,
    ) >= expectedCollateralAmount

  let newDatum =
    ActiveDatum {
      borrowerNFT: inputUtxoId,
      loan: datum.loan,
      loanAmnt: wantedAmount,
      interest: datum.loan,
      interestAmnt: wantedAmount * datum.interestRate / 1000,
      collateral: without_lovelace(output.value),
      loanDuration: datum.loanDuration,
      lenderNFT: inputUtxoId,
      lendDate: end,
      totalInstallments: datum.totalInstallments,
      installmentsRepaid: 0,
    }

  let isDatumCorrect = parsedDatum == newDatum

  let dosProtection = length(flatten(output.value)) <= 21
  and {
    //TODO Anything to enforce regarding stake credentials?
    is_output_to_sc(output, activeLoanScriptHash),
    containsCorrectCollateral,
    isDatumCorrect,
    dosProtection,
  }
}
