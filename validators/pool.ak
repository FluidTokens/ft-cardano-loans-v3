use aiken/collection/dict
use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use aiken/option
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Script}
use cardano/assets.{PolicyId, Value, flatten, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Output, Transaction, find_input}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/constants
use fluidtokens/finance.{
  get_needed_collateral_with_oracles, get_needed_collateral_without_oracles,
}
use fluidtokens/oracle.{retrieve_oracle_data}
use fluidtokens/types/general.{Asset, CollateralAsset}
use fluidtokens/types/loan.{LoanDatum}
use fluidtokens/types/pool.{
  Borrow, Cancel, Liquidation, PoolDatum, PoolMintRedeemer, PoolWithdrawRedeemer,
} as p
use fluidtokens/utils.{
  is_output_to_spend_validator, quantity_of_policy_id, safe_list_at,
  validity_range_within_an_hour,
}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator pool(configNFTPolicyId: ByteArray, configNFTAssetName: ByteArray) {
  mint(redeemer: PoolMintRedeemer, policy_id: PolicyId, self: Transaction) {
    let config =
      utils.get_config(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let inputRefHash = utils.hash_output_ref(redeemer.inputRef)
    let poolOutputs =
      st_utils.get_outputs_to_smart_credential(
        self.outputs,
        Script(config.poolSpendScriptHash),
        Script(policy_id),
        config.smartTokensSpendScriptHash,
      )
    let isInputRefSpent =
      option.is_some(find_input(self.inputs, redeemer.inputRef))

    let mintedTokens =
      list.filter(
        dict.to_pairs(tokens(self.mint, policy_id)),
        fn(Pair(_assetName, quantity)) { quantity > 0 },
      )

    let isEachMintedTokenAccountedFor =
      list.indexed_foldr(
        mintedTokens,
        True,
        fn(index, Pair(assetName, quantity), result) {
          expect result

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
        },
      )

    and {
      isInputRefSpent,
      //We don't need to check of a possible overflow (> 255) as if it happens the minted NFT is not unique anymore and the mint will fail
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
        configNFTPolicyId,
        configNFTAssetName,
      )
    let poolInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(config.poolSpendScriptHash),
        credential,
        config.smartTokensSpendScriptHash,
      )

    //As we loop through the inputs we DO NOT need to ensure that the number of actions is equal to the number of inputs
    list.indexed_foldr(
      poolInputs,
      True,
      fn(index, input, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: PoolDatum = inputDatum
        let redeemerAction = safe_list_at(redeemer.actionsForEachInput, index)

        when redeemerAction is {
          Cancel(poolId) -> and {
              quantity_of(input.output.value, poolPolicyId, poolId) == 1,
              quantity_of(self.mint, poolPolicyId, poolId) == -1,
              authorize_action(
                create_auth(
                  datum.lenderAuth,
                  self.inputs,
                  self.withdrawals,
                  self.extra_signatories,
                  self.mint,
                ),
              ),
            }
          Borrow(
            borrowerAddress,
            outputWithLenderTokenIndex,
            principalOracleRefInputIndex,
            chosenCollateralIndex,
            chosenCollateralOracleRefInputIndex,
            wantedPrincipalAmount,
            poolId,
            permissionedConditionWithdrawIndex,
          ) -> {
            expect (Finite(validFrom), Finite(validTo)) =
              (
                self.validity_range.lower_bound.bound_type,
                self.validity_range.upper_bound.bound_type,
              )
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
            let outputWithLenderToken =
              safe_list_at(self.outputs, outputWithLenderTokenIndex)
            let chosenCollateral =
              safe_list_at(datum.collateralOptions, chosenCollateralIndex)
            let remainingPrincipalAmountAfterBorrow =
              quantity_of(
                input.output.value,
                datum.commonData.principalAsset.policyId,
                datum.commonData.principalAsset.assetName,
              ) - wantedPrincipalAmount

            expect Some(principalLtvAsRational) =
              rational.new(
                safe_list_at(datum.principalLTV, chosenCollateralIndex),
                safe_list_at(datum.principalLTVDivider, chosenCollateralIndex),
              )
            let loanOutputValidationResults =
              if datum.dynamicCollateralPrice {
                let collateralOracleRefInput =
                  safe_list_at(
                    self.reference_inputs,
                    chosenCollateralOracleRefInputIndex,
                  )
                expect Some(chosenCollateralOracleToken) =
                  chosenCollateral.maybeOracleTokenAsset
                expect Some(collateralOraclePriceFeed) =
                  retrieve_oracle_data(
                    collateralOracleRefInput.output.address.payment_credential,
                    collateralOracleRefInput.output.value,
                    self.redeemers,
                    validFrom,
                    validTo,
                    chosenCollateralOracleToken.policyId,
                    chosenCollateralOracleToken.assetName,
                    chosenCollateral.policyId,
                    chosenCollateral.maybeAssetName,
                  )
                let principalOracleRefInput =
                  safe_list_at(
                    self.reference_inputs,
                    principalOracleRefInputIndex,
                  )
                expect Some(principalOraclePriceFeed) =
                  retrieve_oracle_data(
                    principalOracleRefInput.output.address.payment_credential,
                    principalOracleRefInput.output.value,
                    self.redeemers,
                    validFrom,
                    validTo,
                    datum.commonData.principalOracleAsset.policyId,
                    datum.commonData.principalOracleAsset.assetName,
                    datum.commonData.principalAsset.policyId,
                    Some(datum.commonData.principalAsset.assetName),
                  )
                validate_output_to_loan(
                  loanOutput,
                  config.loanPolicyId,
                  config.loanSpendScriptHash,
                  datum,
                  wantedPrincipalAmount,
                  chosenCollateral,
                  get_needed_collateral_with_oracles(
                    wantedPrincipalAmount,
                    principalLtvAsRational,
                    principalOraclePriceFeed,
                    collateralOraclePriceFeed,
                  ),
                  inputUtxoId,
                  validTo,
                  borrowerAddress,
                  poolId,
                )
              } else {
                validate_output_to_loan(
                  loanOutput,
                  config.loanPolicyId,
                  config.loanSpendScriptHash,
                  datum,
                  wantedPrincipalAmount,
                  chosenCollateral,
                  get_needed_collateral_without_oracles(
                    wantedPrincipalAmount,
                    principalLtvAsRational,
                  ),
                  inputUtxoId,
                  validTo,
                  borrowerAddress,
                  poolId,
                )
              }
            and {
              wantedPrincipalAmount > 0,
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
              quantity_of(input.output.value, poolPolicyId, poolId) == 1,
              validity_range_within_an_hour(self),
              loanOutputValidationResults,
              bonds_sent_to_both_parties(
                self.mint,
                outputWithLenderToken,
                config.borrowerBondPolicyId,
                config.lenderBondPolicyId,
                inputUtxoId,
                datum.lenderAddress,
              ),
              or {
                and {
                  remainingPrincipalAmountAfterBorrow == 0,
                  quantity_of(self.mint, poolPolicyId, poolId) == -1,
                },
                and {
                  remainingPrincipalAmountAfterBorrow > 0,
                  index <= 255,
                  validate_eventual_output_to_pool(
                    safe_list_at(self.outputs, index),
                    datum,
                    remainingPrincipalAmountAfterBorrow,
                    poolPolicyId,
                    poolId,
                    config.poolSpendScriptHash,
                    input.output.address.payment_credential,
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

//Expects that the bond minting policy allows minting of a token only if:
//- the AssetName is hash of a tx input
//- the quantity is strictly 1
fn bonds_sent_to_both_parties(
  mintedValue: Value,
  outputWithLenderToken: Output,
  borrowerBondPolicyId: ByteArray,
  lenderBondPolicyId: ByteArray,
  bondId: ByteArray,
  lenderAddress: Address,
) {
  and {
    outputWithLenderToken.address == lenderAddress,
    outputWithLenderToken.datum == InlineDatum(""),
    quantity_of(mintedValue, borrowerBondPolicyId, bondId) == 1,
    quantity_of(outputWithLenderToken.value, lenderBondPolicyId, bondId) == 1,
    length(flatten(outputWithLenderToken.value)) <= 5,
  }
}

fn validate_output_to_loan(
  output: Output,
  loanPolicyId: ByteArray,
  loanSpendScriptHash: ByteArray,
  poolDatum: PoolDatum,
  wantedPrincipalAmount: Int,
  chosenCollateral: CollateralAsset,
  minNeededCollateralAmount: Int,
  loanId: ByteArray,
  end: Int,
  borrowerAddress: Address,
  poolId: ByteArray,
) -> Bool {
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
      originId: bytearray.concat("POOL", poolId),
      borrowerAssetName: loanId,
      lenderAssetName: loanId,
      collateral: chosenCollateral,
      principalAmount: wantedPrincipalAmount,
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
    if chosenCollateral.policyId == "" {
      length(flatten(output.value)) <= 2
    } else {
      length(flatten(output.value)) <= 3
    }
  and {
    correctDestination,
    isDatumCorrect,
    containsLoanNFT,
    containsEnoughCollateral,
    dosProtection,
  }
}

//Expects remainingPrincipalAmountAfterBorrow > 0
fn validate_eventual_output_to_pool(
  output: Output,
  datum: PoolDatum,
  remainingPrincipalAmountAfterBorrow: Int,
  poolPolicyId: ByteArray,
  poolId: ByteArray,
  poolSpendScriptHash: ByteArray,
  poolInputPaymentCredential: Credential,
) {
  expect InlineDatum(outputDatum) = output.datum
  expect parsedDatum: PoolDatum = outputDatum

  let containsCorrectAmount =
    quantity_of(
      output.value,
      datum.commonData.principalAsset.policyId,
      datum.commonData.principalAsset.assetName,
    ) == remainingPrincipalAmountAfterBorrow

  let containsPoolNFT = quantity_of(output.value, poolPolicyId, poolId) == 1

  let isDatumCorrect = parsedDatum == datum

  let dosProtection =
    if datum.commonData.principalAsset.policyId == "" {
      length(flatten(output.value)) <= 2
    } else {
      length(flatten(output.value)) <= 3
    }

  let correctDestination = and {
      output.address.payment_credential == poolInputPaymentCredential,
      if is_output_to_spend_validator(output, poolSpendScriptHash) {
        output.address.stake_credential == datum.lenderAddress.stake_credential
      } else {
        //outputs have been already filtered at the beginning
        True
      },
    }

  and {
    correctDestination,
    isDatumCorrect,
    containsPoolNFT,
    containsCorrectAmount,
    dosProtection,
  }
}
