use aiken/collection/dict
use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use aiken/option
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Script}
use cardano/assets.{
  PolicyId, Value, add, flatten, quantity_of, reduce, tokens, without_lovelace,
}
use cardano/transaction.{InlineDatum, NoDatum, Output, Transaction, find_input}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/constants
use fluidtokens/finance.{
  get_collateral_amount, get_min_principal_for_collateral_with_oracles,
  get_min_principal_for_collateral_without_oracles,
}
use fluidtokens/oracle.{retrieve_oracle_data}
use fluidtokens/types/general.{Asset, CollateralAsset}
use fluidtokens/types/loan.{LoanDatum}
use fluidtokens/types/oracle.{Aggregated, CommonFeedData} as oracle_type
use fluidtokens/types/pool.{CommonData, Liquidation}
use fluidtokens/types/request.{
  Cancel, CancelAfterExpiration, Lend, RequestDatum, RequestMintRedeemer,
  RequestWithdrawRedeemer,
} as r
use fluidtokens/utils.{
  is_output_to_spend_validator, safe_list_at, validity_range_within_an_hour,
}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator request(configNFTPolicyId: PolicyId, configNFTAssetName: ByteArray) {
  mint(redeemer: RequestMintRedeemer, policy_id: PolicyId, self: Transaction) {
    let config =
      utils.get_config(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let inputRefHash = utils.hash_output_ref(redeemer.inputRef)
    let requestOutputs =
      st_utils.get_outputs_to_smart_credential(
        self.outputs,
        Script(config.requestSpendScriptHash),
        Script(policy_id),
        config.smartTokensSpendScriptHash,
      )
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

            expect Some(output) = list.at(requestOutputs, index)
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

    let mintedTokensQuantity =
      reduce(
        self.mint,
        0,
        fn(policyId, _assetName, amount, result) {
          if policyId == policy_id {
            result + amount
          } else {
            result
          }
        },
      )
    and {
      isInputRefSpent,
      isEachMintedTokenAccountedFor,
      mintedTokensQuantity <= 255,
    }
  }

  withdraw(
    redeemer: RequestWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(requestPolicyId) = credential
    let config =
      utils.get_config(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let requestInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(config.requestSpendScriptHash),
        credential,
        config.smartTokensSpendScriptHash,
      )

    //As we loop through the inputs we DO NOT need to ensure that the number of actions is equal to the number of inputs
    list.indexed_foldr(
      requestInputs,
      True,
      fn(index, input, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: RequestDatum = inputDatum
        let redeemerAction = safe_list_at(redeemer.actionsForEachInput, index)

        when redeemerAction is {
          Cancel(requestId) -> and {
              quantity_of(input.output.value, requestPolicyId, requestId) == 1,
              quantity_of(self.mint, requestPolicyId, requestId) == -1,
              authorize_action(
                create_auth(
                  datum.borrowerAuth,
                  self.inputs,
                  self.withdrawals,
                  self.extra_signatories,
                  self.mint,
                ),
              ),
            }
          CancelAfterExpiration(requestId, borrowerOutputIndex) -> {
            expect Finite(validFrom) =
              self.validity_range.lower_bound.bound_type
            let requestExpired = validFrom > datum.requestExpiration
            let borrowerOutput = safe_list_at(self.outputs, borrowerOutputIndex)
            and {
              quantity_of(input.output.value, requestPolicyId, requestId) == 1,
              quantity_of(self.mint, requestPolicyId, requestId) == -1,
              requestExpired,
              validate_collateral_less_penality_output(
                input.output.value,
                borrowerOutput,
                datum.borrowerAddress,
                datum.requestExpirationPenalty,
              ),
            }
          }
          Lend(
            outputWithBorrowerTokenIndex,
            principalOracleRefInputIndex,
            collateralOracleRefInputIndex,
            givenPrincipalAmount,
            requestId,
            permissionedConditionWithdrawIndex,
          ) -> {
            expect Finite(validTo) = self.validity_range.upper_bound.bound_type
            let inputUtxoId = utils.hash_output_ref(input.output_reference)
            let loanOutput =
              safe_list_at(
                get_outputs_to_smart_credential(
                  self.outputs,
                  Script(config.loanSpendScriptHash),
                  Script(config.loanPolicyId),
                  config.smartTokensSpendScriptHash,
                ),
                index,
              )
            let outputWithBorrowerToken =
              safe_list_at(self.outputs, outputWithBorrowerTokenIndex)

            expect Some(principalLtvAsRational) =
              rational.new(datum.principalLTV, datum.principalLTVDivider)
            let collateralAmount =
              get_collateral_amount(input.output.value, datum.collateral)
            let loanOutputValidationResults =
              if datum.dynamicCollateralPrice {
                let collateralOracleRefInput =
                  safe_list_at(
                    self.reference_inputs,
                    collateralOracleRefInputIndex,
                  )
                expect Some(collateralOracleToken) =
                  datum.collateral.maybeOracleTokenAsset
                expect Some(collateralOraclePriceFeed) =
                  retrieve_oracle_data(
                    collateralOracleRefInput.output.address.payment_credential,
                    collateralOracleRefInput.output.value,
                    self.redeemers,
                    validTo,
                    collateralOracleToken.policyId,
                    collateralOracleToken.assetName,
                    datum.collateral.policyId,
                    datum.collateral.maybeAssetName,
                  )
                let principalOracleRefInput =
                  safe_list_at(
                    self.reference_inputs,
                    principalOracleRefInputIndex,
                  )
                expect Some(principalOraclePriceFeed) =
                  if datum.commonData.principalAsset.policyId == "" {
                    Some(
                      Aggregated {
                        common: CommonFeedData {
                          valid_from: 0,
                          valid_to: 0,
                          token: Asset { policyId: "", assetName: "" },
                        },
                        token_price_in_lovelaces: 1,
                        token_price_denominator: 1,
                      },
                    )
                  } else {
                    retrieve_oracle_data(
                      principalOracleRefInput.output.address.payment_credential,
                      principalOracleRefInput.output.value,
                      self.redeemers,
                      validTo,
                      datum.commonData.principalOracleAsset.policyId,
                      datum.commonData.principalOracleAsset.assetName,
                      datum.commonData.principalAsset.policyId,
                      Some(datum.commonData.principalAsset.assetName),
                    )
                  }
                expect
                  givenPrincipalAmount >= get_min_principal_for_collateral_with_oracles(
                    collateralAmount,
                    principalLtvAsRational,
                    principalOraclePriceFeed,
                    collateralOraclePriceFeed,
                  )
                validate_output_to_loan(
                  loanOutput,
                  config.loanPolicyId,
                  config.loanSpendScriptHash,
                  datum,
                  input.output.value,
                  givenPrincipalAmount,
                  datum.collateral,
                  inputUtxoId,
                  validTo,
                  datum.borrowerAddress,
                  requestPolicyId,
                  requestId,
                )
              } else {
                expect
                  givenPrincipalAmount >= get_min_principal_for_collateral_without_oracles(
                    collateralAmount,
                    principalLtvAsRational,
                  )
                validate_output_to_loan(
                  loanOutput,
                  config.loanPolicyId,
                  config.loanSpendScriptHash,
                  datum,
                  input.output.value,
                  givenPrincipalAmount,
                  datum.collateral,
                  inputUtxoId,
                  validTo,
                  datum.borrowerAddress,
                  requestPolicyId,
                  requestId,
                )
              }
            and {
              or {
                datum.permissionedConditionScriptHash == constants.no_permissioned_condition,
                {
                  expect Pair(Script(scriptHash), _amnt) =
                    safe_list_at(
                      self.withdrawals,
                      permissionedConditionWithdrawIndex,
                    )

                  datum.permissionedConditionScriptHash == scriptHash
                },
              },
              quantity_of(input.output.value, requestPolicyId, requestId) == 1,
              quantity_of(self.mint, requestPolicyId, requestId) == -1,
              validity_range_within_an_hour(self),
              loanOutputValidationResults.1st,
              bonds_sent_to_both_parties_and_principal_sent_to_borrower(
                self.mint,
                outputWithBorrowerToken,
                config.borrowerBondPolicyId,
                config.lenderBondPolicyId,
                inputUtxoId,
                datum.borrowerAddress,
                datum.borrowerTokenOutputMustHaveLoanDatum,
                loanOutputValidationResults.2nd,
                givenPrincipalAmount,
                datum.commonData.principalAsset,
              ),
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

fn validate_collateral_less_penality_output(
  requestValue: Value,
  borrowerOutput: Output,
  borrowerAddress: Address,
  requestExpirationPenalty: Int,
) {
  let inputValueNoAda = without_lovelace(requestValue)
  let outputValueNoAda = without_lovelace(borrowerOutput.value)
  let outputAdaCorrect =
    quantity_of(borrowerOutput.value, "", "") >= quantity_of(
      requestValue,
      "",
      "",
    ) - requestExpirationPenalty

  and {
    borrowerOutput.address == borrowerAddress,
    borrowerOutput.datum == NoDatum,
    inputValueNoAda == outputValueNoAda,
    outputAdaCorrect,
  }
}

//Expects that the bond minting policy allows minting of a token only if:
//- the AssetName is hash of a tx input
//- the quantity is strictly 1
fn bonds_sent_to_both_parties_and_principal_sent_to_borrower(
  mintedValue: Value,
  outputWithBorrowerToken: Output,
  borrowerBondPolicyId: ByteArray,
  lenderBondPolicyId: ByteArray,
  bondId: ByteArray,
  borrowerAddress: Address,
  borrowerTokenOutputMustHaveLoanDatum: Bool,
  borrowerBondOutputDatum: LoanDatum,
  givenPrincipalAmount: Int,
  principalAsset: Asset,
) {
  and {
    outputWithBorrowerToken.address == borrowerAddress,
    or {
      borrowerTokenOutputMustHaveLoanDatum == False,
      outputWithBorrowerToken.datum == InlineDatum(borrowerBondOutputDatum),
    },
    quantity_of(outputWithBorrowerToken.value, borrowerBondPolicyId, bondId) == 1,
    quantity_of(
      outputWithBorrowerToken.value,
      principalAsset.policyId,
      principalAsset.assetName,
    ) >= givenPrincipalAmount,
    length(flatten(outputWithBorrowerToken.value)) <= 5,
    quantity_of(mintedValue, lenderBondPolicyId, bondId) == 1,
  }
}

fn validate_output_to_loan(
  output: Output,
  loanPolicyId: ByteArray,
  loanSpendScriptHash: ByteArray,
  requestDatum: RequestDatum,
  requestValue: Value,
  givenPrincipalAmount: Int,
  collateral: CollateralAsset,
  loanId: ByteArray,
  end: Int,
  borrowerAddress: Address,
  requestPolicyId: ByteArray,
  requestId: ByteArray,
) -> (Bool, LoanDatum) {
  let collateralUnchanged =
    if collateral.policyId == "" {
      add(output.value, loanPolicyId, loanId, -1) == add(
        requestValue,
        requestPolicyId,
        requestId,
        -1,
      )
    } else {
      add(without_lovelace(output.value), loanPolicyId, loanId, -1) == add(
        without_lovelace(requestValue),
        requestPolicyId,
        requestId,
        -1,
      )
    }

  let containsLoanNFT = quantity_of(output.value, loanPolicyId, loanId) == 1
  expect InlineDatum(outputDatum) = output.datum
  expect parsedDatum: LoanDatum = outputDatum
  let newDatum =
    LoanDatum {
      commonData: requestDatum.commonData,
      originAssetName: requestId,
      borrowerAssetName: loanId,
      lenderAssetName: loanId,
      collateral,
      principalAmount: givenPrincipalAmount,
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

  let correctDestination =
    if is_output_to_spend_validator(output, loanSpendScriptHash) {
      output.address.stake_credential == borrowerAddress.stake_credential
    } else {
      //outputs have been already filtered at the beginning
      True
    }
  let dosProtection =
    if collateral.policyId == "" {
      length(flatten(output.value)) <= 2
    } else {
      length(flatten(output.value)) <= 3
    }
  (and {
      correctDestination,
      isDatumCorrect,
      containsLoanNFT,
      collateralUnchanged,
      dosProtection,
    }, newDatum)
}
