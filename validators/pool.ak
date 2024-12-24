use aiken/collection/dict
use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use aiken/option
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Script}
use cardano/assets.{PolicyId, Value, flatten, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Output, Transaction, find_input}
use fluidtokens/authorizer.{authorize_action}
use fluidtokens/finance.{token_b_needed_to_purchase_token_a}
use fluidtokens/oracle.{retrieve_oracle_data, validate_oracle_ref_input_value}
use fluidtokens/types/datum.{Liquidation, LoanDatum, LoanInfoDatum, PoolDatum}
use fluidtokens/types/general.{Asset, CollateralAsset}
use fluidtokens/types/redeemer.{
  Aggregated, Borrow, Cancel, Dedicated, OraclePriceFeed, PoolMintRedeemer,
  PoolWithdrawRedeemer, Pooled,
}
use fluidtokens/utils.{
  get_inputs_from_sc_or_delegated_to_sc, get_outputs_to_sc_or_delegated_to_sc,
  is_output_to_sc, quantity_of_policy_id, safe_list_at,
  validity_range_within_an_hour,
}

//TODO Should we limit the max number of minted tokens per tx?
validator pool(configAsset: Asset) {
  mint(redeemer: PoolMintRedeemer, policy_id: PolicyId, self: Transaction) {
    let config =
      utils.get_config(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configAsset.policyId,
        configAsset.assetName,
      )
    let inputRefHash = utils.hash_output_ref(redeemer.inputRef)
    //TODO this is not cip-113 compatible
    let poolOutputs =
      utils.get_outputs_to_sc(self.outputs, config.poolSpendScriptHash)
    let isInputRefSpent =
      option.is_some(find_input(self.inputs, redeemer.inputRef))

    let isEachMintedTokenAccountedFor =
      list.indexed_foldr(
        dict.to_pairs(tokens(self.mint, policy_id)),
        True,
        fn(index, Pair(assetName, quantity), result) {
          expect result

          if quantity > 0 {
            let correctAssetName = and {
                bytearray.at(assetName, 0) == index,
                bytearray.drop(assetName, 1) == bytearray.drop(inputRefHash, 1),
              }

            expect Some(output) = list.at(poolOutputs, index)
            let outputHasUniqueToken = and {
                dict.size(assets.tokens(output.value, policy_id)) == 1,
                assets.quantity_of(output.value, policy_id, assetName) == 1,
              }
            and {
              quantity == 1,
              correctAssetName,
              outputHasUniqueToken,
            }
          } else {
            //Burning the tokens is always allowed
            True
          }
        },
      )
    and {
      isInputRefSpent,
      isEachMintedTokenAccountedFor,
    }
  }

  withdraw(
    redeemer: PoolWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(poolPolicyId) = credential
    let config =
      utils.get_config(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configAsset.policyId,
        configAsset.assetName,
      )
    let poolInputs =
      get_inputs_from_sc_or_delegated_to_sc(
        self.inputs,
        config.poolSpendScriptHash,
      )

    and {
      //Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
      length(poolInputs) == length(redeemer.actionsForEachInput),
      list.indexed_foldr(
        poolInputs,
        True,
        fn(index, inputAndCIP113Control, result) {
          //As all inputs must return True, if any of previous input returned False, then fail
          //The last input is not checked but will return its value at the end, so if False withdraw will fail
          expect result

          let input = inputAndCIP113Control.1st
          expect InlineDatum(inputDatum) = input.output.datum
          expect datum: PoolDatum = inputDatum
          let redeemerAction = safe_list_at(redeemer.actionsForEachInput, index)

          when redeemerAction is {
            Cancel(auth, poolId) -> and {
                quantity_of(input.output.value, poolPolicyId, poolId) == 1,
                quantity_of(self.mint, poolPolicyId, poolId) == -1,
                datum.lenderAuthHash == auth.hash,
                authorize_action(auth),
              }
            Borrow(
              borrowerAddress,
              outputWithLenderTokenIndex,
              chosenCollateralIndex,
              chosenCollateralOracleInputIndex,
              wantedPrincipal,
              poolId,
            ) -> {
              let isCIP113 = inputAndCIP113Control.2nd
              expect Finite(validTo) =
                self.validity_range.upper_bound.bound_type
              let inputUtxoId = utils.hash_output_ref(input.output_reference)
              let loanOutput =
                safe_list_at(
                  get_outputs_to_sc_or_delegated_to_sc(
                    self.outputs,
                    config.loanSpendScriptHash,
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

              let loanOutputValidationResults =
                if datum.dynamicCollateralPrice {
                  let oracleRefInput =
                    safe_list_at(
                      self.reference_inputs,
                      chosenCollateralOracleInputIndex,
                    )
                  expect
                    validate_oracle_ref_input_value(
                      oracleRefInput.output.value,
                      chosenCollateral,
                    )
                  expect Some(oraclePriceFeed) =
                    retrieve_oracle_data(
                      oracleRefInput.output.address.payment_credential,
                      self.redeemers,
                      validTo,
                      chosenCollateral,
                    )
                  validate_output_to_loan(
                    Some(oraclePriceFeed),
                    loanOutput,
                    config.loanPolicyId,
                    config.loanSpendScriptHash,
                    datum,
                    chosenCollateral,
                    chosenCollateralIndex,
                    wantedPrincipal,
                    inputUtxoId,
                    validTo,
                    borrowerAddress,
                    isCIP113,
                    poolId,
                  )
                } else {
                  validate_output_to_loan(
                    None,
                    loanOutput,
                    config.loanPolicyId,
                    config.loanSpendScriptHash,
                    datum,
                    chosenCollateral,
                    chosenCollateralIndex,
                    wantedPrincipal,
                    inputUtxoId,
                    validTo,
                    borrowerAddress,
                    isCIP113,
                    poolId,
                  )
                }

              and {
                wantedPrincipal > 0,
                quantity_of(input.output.value, poolPolicyId, poolId) == 1,
                validity_range_within_an_hour(self),
                loanOutputValidationResults.1st,
                bonds_sent_to_both_parties(
                  self.mint,
                  outputWithLenderToken,
                  config.borrowerBondPolicyId,
                  config.lenderBondPolicyId,
                  inputUtxoId,
                  datum.lenderAddress,
                  datum.lenderTokenOutputMustHaveLoanInfoDatum,
                  loanOutputValidationResults.2nd,
                ),
                or {
                  and {
                    remainingAmount == 0,
                    quantity_of(self.mint, poolPolicyId, poolId) == -1,
                  },
                  and {
                    remainingAmount > 0,
                    validate_eventual_output_to_pool(
                      safe_list_at(self.outputs, index),
                      datum,
                      remainingAmount,
                      poolPolicyId,
                      poolId,
                      config.poolSpendScriptHash,
                      isCIP113,
                    ),
                  },
                },
              }
            }
          }
        },
      ),
    }
  }

  else(_) {
    fail
  }
}

fn bonds_sent_to_both_parties(
  mintedValue: Value,
  outputWithLenderToken: Output,
  borrowerBondPolicyId: ByteArray,
  lenderBondPolicyId: ByteArray,
  bondId: ByteArray,
  lenderAddress: Address,
  lenderTokenOutputMustHaveLoanInfoDatum: Bool,
  lenderBondOutputDatum: LoanInfoDatum,
) {
  and {
    outputWithLenderToken.address == lenderAddress,
    or {
      lenderTokenOutputMustHaveLoanInfoDatum == False,
      outputWithLenderToken.datum == InlineDatum(lenderBondOutputDatum),
    },
    quantity_of(mintedValue, borrowerBondPolicyId, bondId) == 1,
    quantity_of(outputWithLenderToken.value, lenderBondPolicyId, bondId) == 1,
    length(flatten(outputWithLenderToken.value)) <= 5,
  }
}

fn validate_output_to_loan(
  oraclePriceFeed: Option<OraclePriceFeed>,
  output: Output,
  loanPolicyId: ByteArray,
  loanSpendScriptHash: ByteArray,
  poolDatum: PoolDatum,
  chosenCollateral: CollateralAsset,
  chosenCollateralIndex: Int,
  wantedPrincipal: Int,
  loanId: ByteArray,
  end: Int,
  borrowerAddress: Address,
  isCIP113: Bool,
  poolId: ByteArray,
) -> (Bool, LoanInfoDatum) {
  expect Some(principalDivider) =
    list.at(poolDatum.principalLTVDivider, chosenCollateralIndex)

  let minNeededCollateralAmount =
    when oraclePriceFeed is {
      //Dynamic pricing pool
      Some(oraclePriceFeed) -> {
        expect Some(ltv) =
          list.at(poolDatum.principalLTV, chosenCollateralIndex)
        let ltvDivider = principalDivider
        expect Some(ltvAsRational) = rational.new(ltv, ltvDivider)
        expect Some(minNeededCollateralInPrincipalCurrency) =
          rational.div(rational.from_int(wantedPrincipal), ltvAsRational)

        when oraclePriceFeed is {
          Aggregated { token_price_in_lovelaces, denominator, .. } -> {
            expect Some(tokenPrice) =
              rational.new(token_price_in_lovelaces, denominator)

            expect Some(minNeededCollateralAmountAsRational) =
              rational.div(minNeededCollateralInPrincipalCurrency, tokenPrice)
            rational.ceil(minNeededCollateralAmountAsRational)
          }
          Pooled { token_a_amount, token_b_amount, .. } ->
            token_b_needed_to_purchase_token_a(
              minNeededCollateralInPrincipalCurrency,
              token_a_amount,
              token_b_amount,
            )
          Dedicated { token_price, denominator, .. } -> {
            expect Some(tokenPrice) = rational.new(token_price, denominator)

            expect Greater =
              rational.compare(
                tokenPrice,
                minNeededCollateralInPrincipalCurrency,
              )
            1
          }
        }
      }
      //Fixed price pool
      None -> {
        expect Some(singleRequiredAmount) =
          list.at(poolDatum.principalLTV, chosenCollateralIndex)
        expect Some(singleRequiredAmountAsRational) =
          rational.new(singleRequiredAmount, principalDivider)
        expect Some(minNeededCollateralAmountAsRational) =
          rational.div(
            rational.from_int(wantedPrincipal),
            singleRequiredAmountAsRational,
          )
        rational.ceil(minNeededCollateralAmountAsRational)
      }
    }

  let containsEnoughCollateral =
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

  let containsLoanNFT = quantity_of(output.value, loanPolicyId, loanId) == 1
  expect InlineDatum(outputDatum) = output.datum
  expect parsedDatum: LoanDatum = outputDatum
  let newDatum =
    LoanDatum {
      commonData: poolDatum.commonData,
      originAssetName: poolId,
      borrowerAssetName: loanId,
      lenderAssetName: loanId,
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
      is_output_to_sc(output, loanSpendScriptHash),
      toCorrectStaking,
      isDatumCorrect,
      containsLoanNFT,
      containsEnoughCollateral,
      dosProtection,
    }, newDatum)
}

//Expects remainingAmount > 0
fn validate_eventual_output_to_pool(
  output: Output,
  datum: PoolDatum,
  remainingAmount: Int,
  poolPolicyId: ByteArray,
  poolId: ByteArray,
  poolSpendScriptHash: ByteArray,
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

  let containsPoolNFT = quantity_of(output.value, poolPolicyId, poolId) == 1

  let isDatumCorrect = parsedDatum == datum

  let dosProtection = length(flatten(output.value)) <= 5

  let toCorrectStaking = or {
      isCIP113 == True,
      output.address.stake_credential == datum.lenderAddress.stake_credential,
    }

  and {
    is_output_to_sc(output, poolSpendScriptHash),
    toCorrectStaking,
    isDatumCorrect,
    containsPoolNFT,
    containsCorrectAmount,
    dosProtection,
  }
}
