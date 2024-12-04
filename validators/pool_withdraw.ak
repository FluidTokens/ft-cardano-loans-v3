use aiken/cbor
use aiken/collection/dict
use aiken/collection/list.{length}
use aiken/crypto.{ScriptHash}
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use aiken/option
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Script}
use cardano/assets.{PolicyId, Value, flatten, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, find_input,
  find_script_outputs,
}
use types/datum.{ActiveDatum, Liquidation, PoolDatum}
use types/general.{Asset, CollateralAsset}
use types/redeemer.{
  Aggregated, Borrow, Cancel, Dedicated, PoolAction, PoolMintClose,
  PoolMintCreate, PoolMintRedeemer, PoolWithdrawRedeemer, Pooled,
}
use utils.{
  authorize_action, has_pool_id, hash_output_ref,
  hash_to_borrower_id_token_name, hash_to_lender_id_token_name,
  hash_to_loan_id_token_name, is_output_to_sc, pool_id_header,
  quantity_of_policy_id, retrieve_oracle_data, safe_list_at,
  token_b_needed_to_purchase_token_a, token_name_has_header,
  validate_oracle_ref_input, validity_range_within_an_hour,
  value_to_policy_id_token_name_with_header,
}

validator pool {
  // The first byte of minted token names is reserved for the type of token.
  //
  // There is 1 type of token that can be minted:
  // poolId: first byte = 0 = pool_id_header
  mint(redeemer: PoolMintRedeemer, poolPolicyId: PolicyId, self: Transaction) {
    // When minting poolIds the first byte of the token name must be the
    // pool_id_header, and the second byte differentiates the Pools in the
    // transaction.
    //
    // The second byte is needed so we only need a single input reference to
    // create multiple pools in one transaction. We could do this with bitwise
    // operators to save a byte but I don't see simple bitwise operators in
    // Aiken to do them (yet).
    //
    // When creating a pools we must ensure that:
    // - The input that we derive the token names from is spent, and since we
    // may derive multiple poolIds from a single input we need to make sure
    // only 1 of each token name is minted.
    // - That each poolId token goes a different output at the Pool script hash.
    // This is also ensured by having 1 of each pool policy id token at an
    // output.
    // 
    // We can also do additional pool creation checks here if wanted.
    when redeemer is {
      PoolMintCreate(inputRef) -> {
        let mintedOwnPolicyIdTokenNameQuantityPairs =
          dict.to_pairs(assets.tokens(self.mint, poolPolicyId))
        let inputRefHash = hash_output_ref(inputRef)
        let ownOutputs = find_script_outputs(self.outputs, poolPolicyId)

        let isInputRefSpent = option.is_some(find_input(self.inputs, inputRef))

        let isEachMintedTokenAccountedFor =
          list.all(
            mintedOwnPolicyIdTokenNameQuantityPairs,
            fn(Pair(tokenName, quantity)) {
              let isPoolIdTokenName =
                token_name_has_header(tokenName, pool_id_header)

              let matchesInputRefHash =
                bytearray.drop(tokenName, 2) == bytearray.drop(inputRefHash, 2)
              //trace cbor.diagnostic((inputRefHash, tokenName))

              let isPoolOutputValid =
                list.any(
                  ownOutputs,
                  fn(output) {
                    let exactPoolIdCount =
                      assets.quantity_of(output.value, poolPolicyId, tokenName)
                    let isPoolOutputValueValid = and {
                        (dict.size(assets.tokens(output.value, poolPolicyId)) == 1)?,
                        (exactPoolIdCount == 1)?,
                      }
                    //trace cbor.diagnostic(exactPoolIdCount)
                    //trace cbor.diagnostic(output.datum)

                    let isPoolOutputDatumValid =
                      when output.datum is {
                        InlineDatum(poolOutputDatum) ->
                          if poolOutputDatum is PoolDatum {
                            poolOutputDatum.commonData.poolIdTokenName == tokenName
                          } else {
                            False
                          }
                        _ -> False
                      }
                    // we can validate any other pool creation invariants here
                    and {
                      isPoolOutputValueValid?,
                      isPoolOutputDatumValid?,
                    }
                  },
                )

              and {
                isPoolIdTokenName?,
                (quantity == 1)?,
                matchesInputRefHash?,
                isPoolOutputValid?,
              }
            },
          )
        and {
          isInputRefSpent?,
          isEachMintedTokenAccountedFor?,
        }
      }
      // If we are burning pool policy id tokens, then they must be poolIds. If
      // they are poolIds, then they must be at the pool script address.
      // However we must make sure that every such pool policy id token minted
      // are burns.
      PoolMintClose ->
        list.all(
          dict.values(assets.tokens(self.mint, poolPolicyId)),
          fn(quantity) { quantity == -1 },
        )
    }
  }

  spend(
    _mbDatum: Option<Data>,
    _redeemer: Data,
    selfInputRef: OutputReference,
    tx: Transaction,
  ) {
    expect Some(selfInput) = find_input(tx.inputs, selfInputRef)
    let selfCredential = selfInput.output.address.payment_credential
    list.any(
      tx.withdrawals,
      fn(Pair(withdrawCredential, _amount)) {
        withdrawCredential == selfCredential
      },
    )
  }

  publish(_redeemer: Data, _certificate: Data, _tx: Transaction) {
    True
  }

  withdraw(
    redeemer: PoolWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(ownScriptHash) = credential

    let poolInputs =
      list.filter(
        self.inputs,
        fn(input) { has_pool_id(input.output, ownScriptHash) },
      )

    // Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
    expect length(poolInputs) == length(redeemer.actionForEachInput)

    let poolInputActionPairs = list.zip(poolInputs, redeemer.actionForEachInput)

    let (arePoolActionsValid, _remainingOutputs, expectedMintedValue) =
      validate_pool_actions(
        poolInputActionPairs,
        True,
        self.outputs,
        assets.zero,
        ownScriptHash,
        self,
      )

    let isEachMintedTokenAccountedFor =
      assets.tokens(self.mint, ownScriptHash) == assets.tokens(
        expectedMintedValue,
        ownScriptHash,
      )

    and {
      validity_range_within_an_hour(self)?,
      isEachMintedTokenAccountedFor?,
      arePoolActionsValid?,
    }
  }

  else(_) {
    fail
  }
}

// Outputs are expected to correspond to pool inputs in the following way:
//
// [ (poolInput1, poolAction1)
// , ...
// , (poolInputN, poolActionN) ]
// <->
// [ loanOutput1, lenderOutput1, mbPoolOutput1
// , ...
// , loanOutputN, lenderOutputN, mbPoolOutputN ]
//
// As long as loanOutputX, lenderOutputX, mbPoolOutputX are grouped together you
// can put any other outputs before the groups, between the groups, or after the
// groups.
//
// Essentially this function iterates through the pool input action pairs, and
// for each pair, drops outputs until it sees a (loanOutput, lenderOutput,
// mbPoolOutput) group. It then validates the pool input action pair against the
// output group. Then it repeats recursively until there are no more pool inputs
// or a result was false. This allows not linearly scanning because list[index]
// is O(n), but maybe this isn't that much of a problem?
//
// NOTE: Instead of dropping outputs while looking for the relevant outputs for
// an action, we can enforce no spaces between relevant inputs to be a bit more
// efficient.
pub fn validate_pool_actions(
  poolInputActionPairs: List<(Input, PoolAction)>,
  arePrevPoolActionsValid: Bool,
  outputs: List<Output>,
  expectedMintedValue: Value,
  ownScriptHash: ScriptHash,
  tx: Transaction,
) -> (Bool, List<Output>, Value) {
  if arePrevPoolActionsValid {
    when poolInputActionPairs is {
      [] -> (True, outputs, expectedMintedValue)
      [(poolInput, poolAction), ..remainingPoolInputActionPairs] -> {
        expect InlineDatum(rawPoolInputDatum) = poolInput.output.datum
        expect poolInputDatum: PoolDatum = rawPoolInputDatum

        // FIXME: How does this relate to the stake credentials of the Pool
        // input? Additionally, the previous implementation doesn't even need
        // the Pool input to be at the Pool script hash which breaks things. So
        // I've set this to False for now.
        let isCIP113 = False

        let (isPoolActionValid, remainingOutputs, mintedValue) =
          when poolAction is {
            Cancel(auth) -> {
              let isCancelValid = and {
                  poolInputDatum.lenderAuthHash == auth.hash,
                  authorize_action(
                    auth,
                    tx.inputs,
                    tx.withdrawals,
                    tx.extra_signatories,
                    tx.mint,
                  ),
                }

              expect Some(poolIdTokenName) =
                value_to_policy_id_token_name_with_header(
                  poolInput.output.value,
                  ownScriptHash,
                  pool_id_header,
                )

              let mintedValue =
                assets.from_asset(ownScriptHash, poolIdTokenName, -1)

              (isCancelValid, outputs, mintedValue)
            }
            Borrow(
              borrowerAddress,
              chosenCollateralIndex,
              chosenCollateralOracleInputIndex,
              wantedPrincipal,
            ) -> {
              let poolInputRefHash = hash_output_ref(poolInput.output_reference)

              let loanScriptHash = poolInputDatum.loanScriptHash

              let chosenCollateral =
                safe_list_at(
                  poolInputDatum.collateralOptions,
                  chosenCollateralIndex,
                )

              expect Finite(end) = tx.validity_range.upper_bound.bound_type

              let loanIdTokenName = hash_to_loan_id_token_name(poolInputRefHash)
              let lenderIdTokenName =
                hash_to_lender_id_token_name(poolInputRefHash)
              let borrowerIdTokenName =
                hash_to_borrower_id_token_name(poolInputRefHash)

              let targetLtv =
                safe_list_at(poolInputDatum.principalLTV, chosenCollateralIndex)
              let targetLtvDivider =
                safe_list_at(
                  poolInputDatum.principalLTVDivider,
                  chosenCollateralIndex,
                )

              expect [loanOutput,
                lenderOutput, ..potentialRemainingOutputs] =
                list.drop_while(
                  outputs,
                  fn(output) {
                    !is_output_to_sc(output, loanScriptHash)
                  },
                )

              let minNeededCollateralAmount =
                if poolInputDatum.dynamicCollateralPrice {
                  get_min_needed_collateral_amount_with_oracle(
                    poolInputDatum,
                    chosenCollateralIndex,
                    chosenCollateralOracleInputIndex,
                    wantedPrincipal,
                    targetLtv,
                    targetLtvDivider,
                    end,
                    tx,
                  )
                } else {
                  get_min_needed_collateral_amount_without_oracle(
                    wantedPrincipal,
                    targetLtv,
                    targetLtvDivider,
                  )
                }
              let isLoanOutputValid =
                validate_loan_output(
                  loanOutput,
                  loanScriptHash,
                  wantedPrincipal,
                  chosenCollateral,
                  minNeededCollateralAmount,
                  targetLtvDivider,
                  poolInputRefHash,
                  poolInputDatum,
                  borrowerAddress,
                  end,
                  isCIP113,
                )
              let isLenderOutputValid =
                validate_lender_output(
                  lenderOutput,
                  loanScriptHash,
                  poolInputRefHash,
                  poolInputDatum,
                )

              let (isPoolOutputValid, remainingOutputs, mintedPoolIdValue) =
                validate_pool_output(
                  potentialRemainingOutputs,
                  wantedPrincipal,
                  ownScriptHash,
                  poolInput,
                  poolInputDatum,
                  isCIP113,
                )

              let mintedValue =
                assets.from_asset(loanScriptHash, loanIdTokenName, 1)
                  |> assets.add(loanScriptHash, lenderIdTokenName, 1)
                  |> assets.add(loanScriptHash, borrowerIdTokenName, 1)
                  |> assets.merge(mintedPoolIdValue)

              let isBorrowValid = and {
                  (wantedPrincipal > 0)?,
                  isLoanOutputValid?,
                  isLenderOutputValid?,
                  isPoolOutputValid?,
                }

              (isBorrowValid?, remainingOutputs, mintedValue)
            }
          }

        validate_pool_actions(
          remainingPoolInputActionPairs,
          arePrevPoolActionsValid && isPoolActionValid,
          remainingOutputs,
          assets.merge(expectedMintedValue, mintedValue),
          ownScriptHash,
          tx,
        )
      }
    }
  } else {
    (arePrevPoolActionsValid, outputs, expectedMintedValue)
  }
}

fn get_min_needed_collateral_amount_without_oracle(
  wantedPrincipal: Int,
  targetLtv: Int,
  targetLtvDivider: Int,
) -> Int {
  expect Some(targetLtvAsRational) = rational.new(targetLtv, targetLtvDivider)
  expect Some(minNeededCollateralAmountAsRational) =
    rational.div(rational.from_int(wantedPrincipal), targetLtvAsRational)
  let minNeededCollateralAmount =
    rational.ceil(minNeededCollateralAmountAsRational)
  minNeededCollateralAmount
}

fn get_min_needed_collateral_amount_with_oracle(
  poolInputDatum: PoolDatum,
  chosenCollateralIndex: Int,
  chosenCollateralOracleInputIndex: Int,
  wantedPrincipal: Int,
  ltv: Int,
  ltvDivider: Int,
  end: Int,
  tx: Transaction,
) -> Int {
  let chosenCollateral =
    safe_list_at(poolInputDatum.collateralOptions, chosenCollateralIndex)

  let oracleRefInput =
    safe_list_at(tx.reference_inputs, chosenCollateralOracleInputIndex)

  //trace cbor.diagnostic(chosenCollateralOracleInputIndex)
  //trace cbor.diagnostic(tx.reference_inputs)

  expect Some(oraclePriceFeed) =
    retrieve_oracle_data(oracleRefInput, tx.redeemers, end, chosenCollateral)
  expect
    validate_oracle_ref_input(oracleRefInput.output.value, chosenCollateral) == True

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
  minNeededCollateralAmount
}

fn validate_loan_output(
  loanOutput: Output,
  loanScriptHash: ScriptHash,
  wantedPrincipal: Int,
  chosenCollateral: CollateralAsset,
  minNeededCollateralAmount: Int,
  targetLtvDivider: Int,
  poolInputRefHash: ByteArray,
  poolInputDatum: PoolDatum,
  borrowerAddress: Address,
  end: Int,
  isCIP113: Bool,
) -> Bool {
  let containsCorrectCollateral =
    when chosenCollateral.maybeAssetName is {
      Some(chosenCollateralAssetName) ->
        quantity_of(
          loanOutput.value,
          chosenCollateral.policyId,
          chosenCollateralAssetName,
        ) >= minNeededCollateralAmount
      None ->
        quantity_of_policy_id(loanOutput.value, chosenCollateral.policyId) >= minNeededCollateralAmount
    }

  let loanIdTokenName = hash_to_loan_id_token_name(poolInputRefHash)

  let containsLoanIdNft =
    quantity_of(loanOutput.value, loanScriptHash, loanIdTokenName) == 1

  expect InlineDatum(outputDatum) = loanOutput.datum
  expect parsedDatum: ActiveDatum = outputDatum
  let newDatum =
    ActiveDatum {
      commonData: poolInputDatum.commonData,
      collateral: chosenCollateral,
      principalAmount: wantedPrincipal,
      principalDivider: targetLtvDivider,
      lendDate: end,
      repaidInstallments: 0,
      doneRecasts: 0,
    }

  //trace cbor.diagnostic(parsedDatum)
  //trace cbor.diagnostic(newDatum)

  let isLiquidationCorrectlySet =
    when newDatum.commonData.liquidationMode is {
      Liquidation { .. } -> newDatum.collateral.maybeOracleTokenAsset != None
      _ -> True
    }

  let isDatumCorrect = (parsedDatum == newDatum)? && isLiquidationCorrectlySet?

  let toCorrectStaking = or {
      isCIP113 == True,
      loanOutput.address.stake_credential == borrowerAddress.stake_credential,
    }

  let dosProtection = length(flatten(loanOutput.value)) <= 21
  and {
    toCorrectStaking?,
    is_output_to_sc(loanOutput, loanScriptHash)?,
    containsCorrectCollateral?,
    containsLoanIdNft?,
    isDatumCorrect?,
    dosProtection?,
  }
}

fn validate_lender_output(
  lenderOutput: Output,
  loanScriptHash: ScriptHash,
  poolInputRefHash: ByteArray,
  poolInputDatum: PoolDatum,
) -> Bool {
  let lenderIdTokenName = hash_to_lender_id_token_name(poolInputRefHash)

  let isAddressValid = lenderOutput.address == poolInputDatum.lenderAddress

  let isValueValid =
    quantity_of(lenderOutput.value, loanScriptHash, lenderIdTokenName) == 1

  let isDatumValid = True

  and {
    isAddressValid,
    isValueValid,
    isDatumValid,
  }
}

fn validate_pool_output(
  potentialRemainingOutputs: List<Output>,
  wantedPrincipal: Int,
  poolScriptHash: ScriptHash,
  poolInput: Input,
  poolInputDatum: PoolDatum,
  isCIP113: Bool,
) -> (Bool, List<Output>, Value) {
  let poolInputValue = poolInput.output.value

  let principalAsset = poolInputDatum.commonData.principalAsset
  let principalPolicyId = principalAsset.policyId
  let principalAssetName = principalAsset.assetName

  let remainingAmount =
    quantity_of(poolInputValue, principalPolicyId, principalAssetName) - wantedPrincipal

  if remainingAmount > 0 {
    expect [poolOutput, ..remainingOutputs] = potentialRemainingOutputs
    let isAddressValid = and {
        poolOutput.address == poolInput.output.address,
        or {
          isCIP113 == True,
          poolOutput.address.stake_credential == poolInputDatum.lenderAddress.stake_credential,
        },
      }

    let isValueValid = {
      // Min lovelace should only ever decrease because the only thing that
      // changes in a Pool is its principal decreasing. So making sure lovelace
      // doesn't change unless it is the principal is not a problem.
      let expectedPoolOutputValue =
        assets.add(
          poolInputValue,
          principalPolicyId,
          principalAssetName,
          -wantedPrincipal,
        )
      poolOutput.value == expectedPoolOutputValue
    }

    let isDatumValid = {
      expect InlineDatum(rawPoolOutputDatum) = poolOutput.datum
      expect poolOutputDatum: PoolDatum = rawPoolOutputDatum

      poolOutputDatum == poolInputDatum
    }

    let isPoolOutputValid = and {
        isAddressValid,
        isValueValid,
        isDatumValid,
      }

    let mintedOwnPolicyIdTokenValue = assets.zero

    (isPoolOutputValid, remainingOutputs, mintedOwnPolicyIdTokenValue)
  } else {
    // When there is no more principal to lend we need to burn the poolId token
    // if we want to remove the Pool output from the script address.
    let mintedPoolIdTokenValue =
      assets.from_asset(
        poolScriptHash,
        poolInputDatum.commonData.poolIdTokenName,
        -1,
      )

    (True, potentialRemainingOutputs, mintedPoolIdTokenValue)
  }
}
