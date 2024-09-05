use aiken/collection/list.{length}
use aiken/crypto.{sha2_256}
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use aiken/primitive/bytearray
use cardano/address.{Address}
use cardano/assets.{Value, flatten, quantity_of, without_lovelace}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{InlineDatum, Output, OutputReference, Transaction}
use types/datum.{ActiveDatum, OracleLTVPoolDatum}
use types/general.{Asset, CollateralAsset}
use types/redeemer.{
  Accept, Aggregated, Cancel, Dedicated, OracleLTVPoolRedeemer, OraclePriceFeed,
  Pooled,
}
use utils.{
  address_in_signatures, get_inputs_from_sc, get_outputs_to_sc, get_own_hash,
  is_output_to_sc, quantity_of_policy_id, retrieve_oracle_data, safe_list_at,
  token_b_needed_to_purchase_token_a, validity_range_within_an_hour,
  value_to_pairs,
}

validator pool(
  borrowerTokenPolicyId: ByteArray,
  lenderTokenPolicyId: ByteArray,
  activeLoanScriptHash: ByteArray,
  adminAddress: Address,
) {
  spend(
    datumOpt: Option<OracleLTVPoolDatum>,
    redeemer: OracleLTVPoolRedeemer,
    input: OutputReference,
    self: Transaction,
  ) {
    when datumOpt is {
      None -> address_in_signatures(self.extra_signatories, adminAddress)
      Some(datum) -> {
        let ownScriptHash = get_own_hash(input, self.inputs)
        when redeemer is {
          Cancel ->
            address_in_signatures(self.extra_signatories, datum.lenderAddress)
          Accept(
            currentPoolInputIndex,
            outputWithBorrowerTokenIndex,
            outputWithLenderTokenIndex,
            chosenCollateralIndex,
            chosenCollateralOracleInputIndex,
            wantedPrincipal,
          ) -> {
            let inputUtxoId =
              sha2_256(bytearray.push(input.transaction_id, input.output_index))
            expect Some(actualRequestInput) =
              list.at(
                get_inputs_from_sc(self.inputs, ownScriptHash),
                currentPoolInputIndex,
              )
            expect Some(activeOutput) =
              list.at(
                get_outputs_to_sc(self.outputs, activeLoanScriptHash),
                currentPoolInputIndex,
              )
            expect Some(outputWithBorrowerToken) =
              list.at(self.outputs, outputWithBorrowerTokenIndex)
            expect Some(outputWithLenderToken) =
              list.at(self.outputs, outputWithLenderTokenIndex)
            expect Finite(end) = self.validity_range.upper_bound.bound_type
            expect Some(chosenCollateral) =
              list.at(datum.collateralOptions, chosenCollateralIndex)
            let remainingAmount =
              quantity_of(
                actualRequestInput.output.value,
                datum.poolAsset.policyId,
                datum.poolAsset.assetName,
              ) - wantedPrincipal

            let basicChecks = and {
                input == actualRequestInput.output_reference,
                wantedPrincipal > 0,
                remainingAmount >= 0,
                validity_range_within_an_hour(self),
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
                    list.at(
                      self.reference_inputs,
                      chosenCollateralOracleInputIndex,
                    )
                  expect Some(oraclePriceFeed) =
                    retrieve_oracle_data(oracleRefInput, self.redeemers, end)
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
                      oraclePriceFeed,
                    ),
                  }
                } else {
                  validate_output_to_active(
                    activeOutput,
                    activeLoanScriptHash,
                    datum,
                    chosenCollateral,
                    chosenCollateralIndex,
                    wantedPrincipal,
                    inputUtxoId,
                    end,
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
                    safe_list_at(self.outputs, currentPoolInputIndex),
                    datum,
                    remainingAmount,
                    ownScriptHash,
                  ),
                },
              },
            }
          }
        }
      }
    }
  }

  else(ctx: ScriptContext) {
    address_in_signatures(ctx.transaction.extra_signatories, adminAddress)
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
  chosenCollateralIndex: Int,
  wantedPrincipal: Int,
  inputUtxoId: ByteArray,
  end: Int,
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
      borrowerNFT: inputUtxoId,
      loan: poolDatum.poolAsset,
      loanAmnt: wantedPrincipal,
      interest: poolDatum.poolAsset,
      interestAmnt: wantedPrincipal * poolDatum.interestRate / 1000,
      collateral: value_to_pairs(without_lovelace(output.value)),
      loanDuration: poolDatum.loanDuration,
      lenderNFT: inputUtxoId,
      lendDate: end,
      totalInstallments: poolDatum.totalInstallments,
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

fn validate_output_to_active_with_oracle(
  output: Output,
  activeLoanScriptHash: ByteArray,
  poolDatum: OracleLTVPoolDatum,
  chosenCollateral: CollateralAsset,
  chosenCollateralIndex: Int,
  wantedPrincipal: Int,
  inputUtxoId: ByteArray,
  end: Int,
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
      borrowerNFT: inputUtxoId,
      loan: poolDatum.poolAsset,
      loanAmnt: wantedPrincipal,
      interest: poolDatum.poolAsset,
      interestAmnt: wantedPrincipal * poolDatum.interestRate / 1000,
      collateral: value_to_pairs(without_lovelace(output.value)),
      loanDuration: poolDatum.loanDuration,
      lenderNFT: inputUtxoId,
      lendDate: end,
      totalInstallments: poolDatum.totalInstallments,
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

//Expects remainingAmount > 0
fn validate_eventual_output_to_pool(
  output: Output,
  datum: OracleLTVPoolDatum,
  remainingAmount: Int,
  ownScriptHash: ByteArray,
) {
  expect InlineDatum(outputDatum) = output.datum
  expect parsedDatum: OracleLTVPoolDatum = outputDatum

  let containsCorrectAmount =
    quantity_of(
      output.value,
      datum.poolAsset.policyId,
      datum.poolAsset.assetName,
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
