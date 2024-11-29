use aiken/collection/dict
use aiken/collection/list.{length}
use aiken/crypto.{ScriptHash}
use aiken/interval.{Finite, Interval}
use aiken/option
use cardano/address.{Address, Credential, Script}
use cardano/assets.{AssetName, PolicyId, Value, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, find_input,
}
use finance.{
  can_liquidate, get_collateral_value_in_principal_currency, get_remaining_debt,
  get_repayment_amount, is_recasting_permitted, is_repayment_late,
}
use types/datum.{
  ActiveDatum, ConfigDatum, DutchAuctionDatum, Liquidation,
  NoLiquidationDutchAuctionClaim, NoLiquidationFullCollateralClaim, PoolDatum,
  RepaymentDatum, RepaymentDatumWithBond,
}
use types/general.{Asset, CollateralAsset}
use types/redeemer.{
  ActiveAction, ActiveWithdrawRedeemer, AddCollateral, Claim, Recast, Repay,
}
use utils.{
  has_pool_id, hash_output_ref, hash_to_borrower_id_token_name,
  hash_to_lender_id_token_name, hash_to_loan_id_token_name,
  hash_to_repayment_id_token_name, is_nft_spent, is_output_to_sc, loan_id_header,
  output_to_policy_id_token_name_with_header, quantity_of_policy_id,
  repayment_id_header, replace_first_byte, retrieve_oracle_data, safe_list_at,
  token_name_has_header, validate_oracle_ref_input, value_has_exact_id_header,
  value_without_policy_id_as_list,
}

pub type LoanMintRedeemer {
  LoanMintPoolBorrow
  LoanMint
}

validator loan(
  poolScriptHash: ByteArray,
  repaymentScriptHash: ByteArray,
  dutchAuctionScriptHash: ByteArray,
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  // The first byte of minted token names is reserved for teh type of token
  //
  // There are 4 types of tokens that can be minted:
  // loanId: first byte = 0 = loan_id_header
  // lenderId: first byte = 1 = lender_id_header
  // borrowerId: first byte = 2 = borrower_id_header
  // repaymentId: first byte = 3 = repayment_id_header
  mint(redeemer: LoanMintRedeemer, loanPolicyId: PolicyId, tx: Transaction) {
    // We separate Pool Borrow and Loan Action mint validations therefore we
    // cannot combine the two actions in one tx.
    when redeemer is {
      // Ensure that there is a Pool input corresponding to each minted token.
      //
      // How many tokens are minted and where they go are the responsibility of
      // the Pool withdraw validator.
      //
      // Pool spend validators delegate to their corresponding withdraw
      // validators. Each Pool action should determine the exact number of Loan
      // policy id tokens minted and where they go.
      //
      // NOTE: that the Pool script does not know the Loan script hash. A Pool
      // instead has the Loan script hash recorded in its datum when it is
      // created.
      //
      // This means when minting Loan policy id tokens during a Pool Borrow we
      // need to check that the Pool has its datum loanScriptHash equal to this
      // Loan script hash.
      LoanMintPoolBorrow -> {
        let poolInputs =
          list.filter(
            tx.inputs,
            fn(input) { has_pool_id(input.output, poolScriptHash) },
          )

        let mintedLoanPolicyIdTokenNameQuantityPairs =
          dict.to_pairs(assets.tokens(tx.mint, loanPolicyId))

        list.all(
          mintedLoanPolicyIdTokenNameQuantityPairs,
          fn(Pair(tokenName, quantity)) {
            and {
              quantity == 1,
              list.any(
                poolInputs,
                fn(poolInput) {
                  let poolInputRefHash =
                    hash_output_ref(poolInput.output_reference)
                  let loanIdTokenName =
                    hash_to_loan_id_token_name(poolInputRefHash)
                  let lenderIdTokenName =
                    hash_to_lender_id_token_name(poolInputRefHash)
                  let borrowerIdTokenName =
                    hash_to_borrower_id_token_name(poolInputRefHash)
                  let isPoolLoanScriptHashValid =
                    when poolInput.output.datum is {
                      InlineDatum(datum) ->
                        if datum is PoolDatum {
                          datum.loanScriptHash == loanPolicyId
                        } else {
                          False
                        }
                      _ -> False
                    }
                  and {
                    or {
                      tokenName == loanIdTokenName,
                      tokenName == lenderIdTokenName,
                      tokenName == borrowerIdTokenName,
                    },
                    isPoolLoanScriptHashValid,
                  }
                },
              ),
            }
          },
        )
      }
      // Ensure there is a Loan input corresponding to each minted token.
      //
      // How many tokens are minted and where they go are the responsibility of
      // the Loan withdraw validator.
      //
      // Loan spend validators delegate to their corresponding withdraw
      // validators. Each Loan action should determine the exact number of Loan
      // policy id tokens minted and where they go.
      LoanMint -> {
        let loanInputIdTokenNames =
          list.filter_map(
            tx.inputs,
            fn(input) {
              output_to_policy_id_token_name_with_header(
                input.output,
                loanPolicyId,
                loan_id_header,
              )
            },
          )

        let mintedLoanPolicyIdTokenNameQuantityPairs =
          dict.to_pairs(assets.tokens(tx.mint, loanPolicyId))

        list.all(
          mintedLoanPolicyIdTokenNameQuantityPairs,
          fn(Pair(tokenName, quantity)) {
            or {
              and {
                quantity == 1,
                // When creating repayment ids we want them to have the same
                // token name tail as the loan id. This way when collecting
                // repayments we can know which repayments are ours onchain due
                // to the fact that the lender id has the same token name tail
                // (and policy id) as the repayment id allowing us to perfectly
                // validate profit calculations.
                token_name_has_header(tokenName, repayment_id_header),
                list.any(
                  loanInputIdTokenNames,
                  fn(loanInputIdTokenName) {
                    let repaymentIdTokenName =
                      replace_first_byte(
                        loanInputIdTokenName,
                        repayment_id_header,
                      )

                    tokenName == repaymentIdTokenName
                  },
                ),
              },
              and {
                quantity < 0,
                or {
                  // LoanIds are always at Loan script address so burning it
                  // requires it be an input to the tx which means it was spent
                  // which meant it was validated by withdraw validator which
                  // means the burn reason and amount was validated.
                  token_name_has_header(tokenName, loan_id_header),
                  // RepaymentIds go to the Repayment script address when
                  // created. It would be nice to burn them when the repayment
                  // is picked up, but if not it doesn't hurt to allow them to
                  // be burned arbitrarily after pick up.
                  token_name_has_header(tokenName, repayment_id_header),
                },
              },
            }
          },
        )
      }
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
    redeemer: ActiveWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Finite(validFrom) = self.validity_range.lower_bound.bound_type
    expect Finite(validTo) = self.validity_range.upper_bound.bound_type

    expect Script(ownScriptHash) = credential

    let loanInputs =
      list.filter_map(
        self.inputs,
        fn(input) {
          option.map(
            output_to_policy_id_token_name_with_header(
              input.output,
              ownScriptHash,
              loan_id_header,
            ),
            fn(tokenName) { (tokenName, input) },
          )
        },
      )

    //Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
    expect length(loanInputs) == length(redeemer.actionForEachInput)

    let loanInputActionPairs = list.zip(loanInputs, redeemer.actionForEachInput)

    let (areLoanActionsValid, _remainingOutputs, expectedMintedValue) =
      validate_loan_actions(
        loanInputActionPairs,
        True,
        self.outputs,
        assets.zero,
        ownScriptHash,
        repaymentScriptHash,
        dutchAuctionScriptHash,
        validFrom,
        validTo,
        self,
      )

    let isEachMintedTokenAccountedFor =
      assets.tokens(self.mint, ownScriptHash) == assets.tokens(
        expectedMintedValue,
        ownScriptHash,
      )

    and {
      areLoanActionsValid,
      isEachMintedTokenAccountedFor,
    }
  }

  else(_) {
    fail
  }
}

// Outputs are expected to correspond to pool inputs in the following way
// (example):
//
// [ (loanInput1, claimAction1)
// , (loanInput2, collateralAddAction2)
// , (loanInput3, recastAction3)
// , (loanInput4, repayAction4) ]
// <->
// [ ...
// , mbBorrowerPartialOutput1
// , ...
// , loanOutput2
// , ...
// , recastRepaymentOutput3
// , mbRecastLoanOutput3
// , ...
// , repaymentOutputN,
// , mbRepayLoanOutputN
// , ... ]
//
// Essentially this function iterates through the pool input action pairs, and
// for each pair, drops outputs until it sees relevant outputs for the action.
// It then validates the pool input action pair against the output group. Then
// it repeats recursively until there are no more pool inputs or a result was
// false. This allows not linearly scanning because list[index] is O(n), but
// maybe this isn't that much of a problem?
//
// NOTE: Instead of dropping outputs while looking for the relevant outupts for
// an action, we can enforce no spaces between relevant inputs to be a bit more
// efficient.
pub fn validate_loan_actions(
  loanInputActionPairs: List<((AssetName, Input), ActiveAction)>,
  arePrevActionsValid: Bool,
  outputs: List<Output>,
  expectedMintedValue: Value,
  loanScriptHash: ScriptHash,
  repaymentScriptHash: ScriptHash,
  dutchAuctionScriptHash: ScriptHash,
  validFrom: Int,
  validTo: Int,
  tx: Transaction,
) -> (Bool, List<Output>, Value) {
  if arePrevActionsValid {
    let loanIdPolicyId = loanScriptHash
    let lenderIdPolicyId = loanScriptHash
    let borrowerIdPolicyId = loanScriptHash

    when loanInputActionPairs is {
      [] -> (True, outputs, expectedMintedValue)
      [((loanIdTokenName, loanInput), action), ..remainingLoanInputActionPairs] -> {
        expect InlineDatum(rawLoanInputDatum) = loanInput.output.datum
        expect loanInputDatum: ActiveDatum = rawLoanInputDatum

        let lenderIdTokenName = loanInputDatum.lenderAssetName
        let borrowerIdTokenName = loanInputDatum.borrowerAssetName

        // FIXME: How does this relate to the stake credentials of the input?
        // Additionally, the previous implementation doesn't even need the input
        // to be at the Loan script hash which is really odd. So I've set this
        // to False for now.
        let isCIP113 = False

        let (isActionValid, remainingOutputs, mintedValue) =
          when action is {
            Claim(
              lenderInputIndex,
              configRefInputIndex,
              collateralOracleRefInputIndex,
              lenderAuthHash,
              lenderAddress,
            ) -> {
              expect Some(lenderIdInput) = list.at(tx.inputs, lenderInputIndex)

              let isLenderIdInputSpent =
                is_nft_spent(lenderIdPolicyId, lenderIdTokenName, lenderIdInput)

              let isRepaymentLate =
                is_repayment_late(
                  validFrom,
                  loanInputDatum.lendDate,
                  loanInputDatum.commonData.initialGracePeriod,
                  loanInputDatum.repaidInstallments,
                  loanInputDatum.commonData.installmentPeriod,
                  loanInputDatum.commonData.repaymentTimeWindow,
                )

              let (
                isLiquidationValid,
                remainingOutputs,
                mintedLiquidationIdValue,
              ) =
                when loanInputDatum.commonData.liquidationMode is {
                  NoLiquidationFullCollateralClaim ->
                    (isRepaymentLate, outputs, assets.zero)
                  NoLiquidationDutchAuctionClaim -> {
                    expect Finite(validTo) =
                      tx.validity_range.upper_bound.bound_type

                    let configRefInput =
                      safe_list_at(tx.reference_inputs, configRefInputIndex)

                    expect [dutchAuctionOutput, ..remainingOutputs] =
                      list.drop_while(
                        outputs,
                        fn(output) {
                          !is_output_to_sc(output, dutchAuctionScriptHash)
                        },
                      )

                    let isDutchAuctionClaimValid = and {
                        isRepaymentLate,
                        validate_output_to_dutch_auction(
                          loanInput,
                          lenderIdInput,
                          dutchAuctionOutput,
                          validTo,
                          lenderAuthHash,
                          lenderAddress,
                          loanInputDatum.commonData.principalAsset,
                          get_remaining_debt(
                            loanInputDatum.commonData.repaymentMode,
                            loanInputDatum.principalAmount,
                            loanInputDatum.principalDivider,
                            loanInputDatum.commonData.interestRate,
                            loanInputDatum.commonData.totalInstallments,
                            loanInputDatum.repaidInstallments,
                          ),
                          utils.get_config(
                            configRefInput,
                            configNFTPolicyId,
                            configNFTAssetName,
                          ),
                        ),
                      }

                    (isDutchAuctionClaimValid, remainingOutputs, assets.zero)
                  }
                  Liquidation(ltv, ltvDivider, partialLiquidation) -> {
                    let oracleRefInput =
                      safe_list_at(
                        tx.reference_inputs,
                        collateralOracleRefInputIndex,
                      )

                    expect Some(oraclePriceFeed) =
                      retrieve_oracle_data(
                        oracleRefInput,
                        tx.redeemers,
                        validTo,
                        loanInputDatum.collateral,
                      )

                    let collateralValueInPrincipalCurrency =
                      get_collateral_value_in_principal_currency(
                        oraclePriceFeed,
                        loanInputDatum.collateral,
                        loanInput.output.value,
                      )

                    let isCollateralOracleValid =
                      validate_oracle_ref_input(
                        oracleRefInput.output.value,
                        loanInputDatum.collateral,
                      )

                    let (
                      isPartialLiquidationValid,
                      remainingOutputs,
                      mintedRepaymentIdValue,
                    ) =
                      if !partialLiquidation {
                        (True, outputs, assets.zero)
                      } else {
                        validate_borrower_leftover_output(
                          outputs,
                          loanScriptHash,
                          loanInput.output_reference,
                          loanInputDatum,
                          borrowerIdTokenName,
                          repaymentScriptHash,
                          "partial_liquidation",
                          collateralValueInPrincipalCurrency,
                        )
                      }

                    let isLiquidatable = or {
                        isRepaymentLate,
                        can_liquidate(
                          collateralValueInPrincipalCurrency,
                          loanInputDatum.principalAmount,
                          loanInputDatum.principalDivider,
                          ltv,
                          ltvDivider,
                        ),
                      }

                    let isLiquidationValid = and {
                        isCollateralOracleValid,
                        isLiquidatable,
                        isPartialLiquidationValid,
                      }

                    (
                      isLiquidationValid,
                      remainingOutputs,
                      mintedRepaymentIdValue,
                    )
                  }
                }

              let isClaimValid = and {
                  isLenderIdInputSpent,
                  isLiquidationValid,
                }

              // The loan is closed in every case so we must burn the loanId
              let mintedLoanIdValue =
                assets.from_asset(loanIdPolicyId, loanIdTokenName, -1)

              let mintedValue =
                assets.merge(mintedLoanIdValue, mintedLiquidationIdValue)

              (isClaimValid, remainingOutputs, mintedValue)
            }
            Repay(borrowerIdInputIndex) -> {
              expect Some(borrowerIdInput) =
                list.at(tx.inputs, borrowerIdInputIndex)

              let isBorrowerIdInputSpent =
                is_nft_spent(
                  borrowerIdPolicyId,
                  borrowerIdTokenName,
                  borrowerIdInput,
                )

              let (
                isRepaymentOutputValid,
                remainingOutputs1,
                mintedRepaymentIdValue,
              ) =
                validate_repayment_output(
                  outputs,
                  loanScriptHash,
                  loanInput.output_reference,
                  loanInputDatum,
                  lenderIdTokenName,
                  repaymentScriptHash,
                  "installment_repayment",
                  validFrom,
                )

              let (isLoanOutputValid, remainingOutputs2, mintedLoanIdValue) =
                validate_repay_loan_output(
                  remainingOutputs1,
                  loanScriptHash,
                  loanIdTokenName,
                  loanInput.output.value,
                  loanInputDatum,
                )
              let isRepaymentValid = and {
                  isBorrowerIdInputSpent,
                  isRepaymentOutputValid,
                  isLoanOutputValid,
                }

              let mintedValue =
                assets.merge(mintedRepaymentIdValue, mintedLoanIdValue)

              (isRepaymentValid, remainingOutputs2, mintedValue)
            }
            AddCollateral(borrowerIdInputIndex, addedCollateralAmount) -> {
              expect Some(borrowerIdInput) =
                list.at(tx.inputs, borrowerIdInputIndex)

              let isBorrowerIdInputSpent =
                is_nft_spent(
                  borrowerIdPolicyId,
                  borrowerIdTokenName,
                  borrowerIdInput,
                )

              let (isLoanOutputValid, remainingOutputs) =
                validate_add_collateral_loan_output(
                  outputs,
                  loanScriptHash,
                  loanIdTokenName,
                  loanInput.output.address,
                  loanInput.output.value,
                  loanInputDatum,
                  addedCollateralAmount,
                  isCIP113,
                )

              let isAddCollateralValid = and {
                  addedCollateralAmount > 0,
                  isBorrowerIdInputSpent,
                  isLoanOutputValid,
                }
              (isAddCollateralValid, remainingOutputs, assets.zero)
            }
            Recast(borrowerIdInputIndex, principalPaid) -> {
              expect Some(borrowerIdInput) =
                list.at(tx.inputs, borrowerIdInputIndex)

              let isBorrowerIdInputSpent =
                is_nft_spent(
                  borrowerIdPolicyId,
                  borrowerIdTokenName,
                  borrowerIdInput,
                )

              let isRecastingPermitted =
                is_recasting_permitted(
                  loanInputDatum.commonData.repaymentMode,
                  loanInputDatum.doneRecasts,
                )

              let (
                isRepaymentOutputValid,
                remainingOutputs1,
                mintedRepaymentIdValue,
              ) =
                validate_repayment_output(
                  outputs,
                  loanScriptHash,
                  loanInput.output_reference,
                  loanInputDatum,
                  lenderIdTokenName,
                  repaymentScriptHash,
                  "recast",
                  validFrom,
                )

              let (isLoanOutputValid, remainingOutputs2, mintedLoanIdValue) =
                validate_recast_loan_output(
                  remainingOutputs1,
                  loanScriptHash,
                  loanIdTokenName,
                  loanInput.output.address,
                  loanInput.output.value,
                  loanInputDatum,
                  principalPaid,
                  isCIP113,
                )

              let isRecastValid = and {
                  principalPaid > 0,
                  isBorrowerIdInputSpent,
                  isRecastingPermitted,
                  isRepaymentOutputValid,
                  isLoanOutputValid,
                }

              let mintedValue =
                assets.merge(mintedRepaymentIdValue, mintedLoanIdValue)

              (isRecastValid, remainingOutputs2, mintedValue)
            }
          }

        // validate the next action
        validate_loan_actions(
          remainingLoanInputActionPairs,
          arePrevActionsValid && isActionValid,
          remainingOutputs,
          assets.merge(expectedMintedValue, mintedValue),
          loanScriptHash,
          repaymentScriptHash,
          dutchAuctionScriptHash,
          validFrom,
          validTo,
          tx,
        )
      }
    }
  } else {
    (arePrevActionsValid, outputs, expectedMintedValue)
  }
}

fn validate_borrower_leftover_output(
  outputs: List<Output>,
  loanPolicyId: PolicyId,
  loanInputRef: OutputReference,
  loanInputDatum: ActiveDatum,
  borrowerIdTokenName: AssetName,
  repaymentScriptHash: ScriptHash,
  repaymentActionName: ByteArray,
  collateralValueAsPrincipal: Int,
) -> (Bool, List<Output>, Value) {
  let borrowerDebt =
    get_remaining_debt(
      loanInputDatum.commonData.repaymentMode,
      loanInputDatum.principalAmount,
      loanInputDatum.principalDivider,
      loanInputDatum.commonData.interestRate,
      loanInputDatum.commonData.totalInstallments,
      loanInputDatum.repaidInstallments,
    )

  let leftoverAmount = collateralValueAsPrincipal - borrowerDebt

  if leftoverAmount <= 0 {
    (True, outputs, assets.zero)
  } else {
    expect [repaymentOutput, ..remainingOutputs] =
      list.drop_while(
        outputs,
        fn(output) { !is_output_to_sc(output, repaymentScriptHash) },
      )

    let loanInputRefHash = hash_output_ref(loanInputRef)
    let repaymentIdTokenName = hash_to_repayment_id_token_name(loanInputRefHash)

    let isValueValid = {
      let principalPolicyId = loanInputDatum.commonData.principalAsset.policyId
      let principalAssetName =
        loanInputDatum.commonData.principalAsset.assetName
      and {
        assets.quantity_of(
          repaymentOutput.value,
          loanPolicyId,
          repaymentIdTokenName,
        ) == 1,
        assets.quantity_of(
          repaymentOutput.value,
          principalPolicyId,
          principalAssetName,
        ) == leftoverAmount,
      }
    }

    let borrowerAsset =
      Asset { policyId: loanPolicyId, assetName: borrowerIdTokenName }

    let isDatumValid = {
      expect InlineDatum(rawRepaymentOutputDatum) = repaymentOutput.datum
      expect repaymentOutputDatum: RepaymentDatum = rawRepaymentOutputDatum

      let expectedRepaymentOutputDatum =
        RepaymentDatumWithBond {
          action: repaymentActionName,
          // dummy value
          data: 0,
          ownerAsset: borrowerAsset,
        }
      repaymentOutputDatum == expectedRepaymentOutputDatum
    }

    let isValid = and {
        isValueValid,
        isDatumValid,
      }

    let mintedValue = assets.from_asset(loanPolicyId, repaymentIdTokenName, 1)

    (isValid, remainingOutputs, mintedValue)
  }
}

// Takes a list of outputs, discards outputs until it finds the first output
// with this loan's repaymentId and checks if it is valid.
//
// Returns (isValid, remaining outputs, minted tokens)
fn validate_repayment_output(
  outputs: List<Output>,
  loanPolicyId: PolicyId,
  loanInputRef: OutputReference,
  loanInputDatum: ActiveDatum,
  lenderIdTokenName: AssetName,
  repaymentScriptHash: ScriptHash,
  repaymentActionName: ByteArray,
  validFrom: Int,
) -> (Bool, List<Output>, Value) {
  let loanInputRefHash = hash_output_ref(loanInputRef)

  expect [repaymentOutput, ..remainingOutputs] =
    list.drop_while(
      outputs,
      fn(output) { !is_output_to_sc(output, repaymentScriptHash) },
    )

  let isRepaymentLate =
    is_repayment_late(
      validFrom,
      loanInputDatum.lendDate,
      loanInputDatum.commonData.initialGracePeriod,
      loanInputDatum.repaidInstallments,
      loanInputDatum.commonData.installmentPeriod,
      loanInputDatum.commonData.repaymentTimeWindow,
    )

  let repaymentAmount =
    get_repayment_amount(
      loanInputDatum.commonData.repaymentMode,
      loanInputDatum.principalAmount,
      loanInputDatum.principalDivider,
      loanInputDatum.commonData.interestRate,
      loanInputDatum.commonData.totalInstallments,
      isRepaymentLate,
      loanInputDatum.commonData.penaltyFeeForLateRepayment,
    )

  let principalPolicyId = loanInputDatum.commonData.principalAsset.policyId
  let principalAssetName = loanInputDatum.commonData.principalAsset.assetName

  let repaymentIdTokenName =
    replace_first_byte(loanInputRefHash, repayment_id_header)

  let loanInputRefHash = hash_output_ref(loanInputRef)

  let isValueValid = and {
      value_has_exact_id_header(
        repaymentOutput.value,
        loanPolicyId,
        loanInputRefHash,
        repayment_id_header,
      ),
      quantity_of(repaymentOutput.value, principalPolicyId, principalAssetName) >= repaymentAmount,
    }

  let isDatumValid = {
    expect InlineDatum(rawRepaymentOutputDatum) = repaymentOutput.datum
    expect repaymentOutputDatum: RepaymentDatum = rawRepaymentOutputDatum

    let lenderAsset =
      Asset { policyId: loanPolicyId, assetName: lenderIdTokenName }

    let expectedRepaymentOutputDatum =
      RepaymentDatumWithBond {
        action: repaymentActionName,
        data: loanInputDatum.repaidInstallments + 1,
        ownerAsset: lenderAsset,
      }

    repaymentOutputDatum == expectedRepaymentOutputDatum
  }

  // payment credential is checked by `is_output_to_sc` but do we care
  // about the stake credential?
  let isRepaymentOutputValid = and {
      isValueValid,
      isDatumValid,
    }

  let mintedTokens = assets.from_asset(loanPolicyId, repaymentIdTokenName, 1)

  (isRepaymentOutputValid, remainingOutputs, mintedTokens)
}

// If not the last installment, takes a list of outputs, discards outputs until
// it finds the first output with this loan's loanId and checks if it is valid.
//
// Returns (isValid, remaining outputs, minted tokens)
fn validate_repay_loan_output(
  outputs: List<Output>,
  loanPolicyId: PolicyId,
  loanIdTokenName: AssetName,
  loanInputValue: Value,
  loanInputDatum: ActiveDatum,
) -> (Bool, List<Output>, Value) {
  if loanInputDatum.repaidInstallments == loanInputDatum.commonData.totalInstallments - 1 {
    (True, outputs, assets.from_asset(loanPolicyId, loanIdTokenName, -1))
  } else {
    expect [loanOutput, ..remainingOutputs] =
      list.drop_while(
        outputs,
        fn(output) { !is_output_to_sc(output, loanPolicyId) },
      )

    let isValueValid = and {
        assets.quantity_of(loanOutput.value, loanPolicyId, loanIdTokenName) == 1,
        loanOutput.value == loanInputValue,
      }

    let isDatumValid = {
      expect InlineDatum(outputDatum) = loanOutput.datum
      expect loanOutputDatum: ActiveDatum = outputDatum

      let expectedLoanOutputDatum =
        ActiveDatum {
          ..loanInputDatum,
          repaidInstallments: loanInputDatum.repaidInstallments + 1,
        }

      loanOutputDatum == expectedLoanOutputDatum
    }

    // address is checked by `is_output_to_sc` but do we care about the stake
    // credential?
    let isLoanOutputValid = and {
        isValueValid,
        isDatumValid,
      }

    (isLoanOutputValid, remainingOutputs, assets.zero)
  }
}

// Takes a list of outputs, discards outputs until it finds the first output
// with this loan's repaymentId and checks if it is valid.
//
// NOTE: The previous implementation doesn't use addedCollateralAmount in the
// collateralPolicyId only case. Was that intentional?
//
// Returns (isValid, remaining outputs, minted tokens)
fn validate_add_collateral_loan_output(
  outputs: List<Output>,
  loanPolicyId: PolicyId,
  loanIdTokenName: AssetName,
  loanInputAddress: Address,
  loanInputValue: Value,
  loanInputDatum: ActiveDatum,
  addedCollateralAmount: Int,
  isCIP113: Bool,
) -> (Bool, List<Output>) {
  expect [loanOutput, ..remainingOutputs] =
    list.drop_while(
      outputs,
      fn(output) { !is_output_to_sc(output, loanPolicyId) },
    )

  let isAddressValid =
    is_continuing_address_valid(loanInputAddress, loanOutput.address, isCIP113)

  let isValueValid = {
    let collateralPolicyId = loanInputDatum.collateral.policyId

    and {
      assets.quantity_of(loanOutput.value, loanPolicyId, loanIdTokenName) == 1,
      when loanInputDatum.collateral.maybeAssetName is {
        None -> {
          let loanInputCollateralAmount =
            quantity_of_policy_id(loanInputValue, collateralPolicyId)
          let loanOutputCollateralAmount =
            quantity_of_policy_id(loanOutput.value, collateralPolicyId)
          let loanInputValueWithoutCollateral =
            value_without_policy_id_as_list(loanInputValue, collateralPolicyId)
          let loanOutputValueWithoutCollateral =
            value_without_policy_id_as_list(
              loanOutput.value,
              collateralPolicyId,
            )
          and {
            loanOutputCollateralAmount == loanInputCollateralAmount + addedCollateralAmount,
            loanOutputValueWithoutCollateral == loanInputValueWithoutCollateral,
          }
        }
        Some(collateralAssetName) -> {
          let expectedLoanOutputValue =
            assets.add(
              loanInputValue,
              collateralPolicyId,
              collateralAssetName,
              addedCollateralAmount,
            )
          loanOutput.value == expectedLoanOutputValue
        }
      },
    }
  }

  let isDatumValid = {
    expect InlineDatum(rawLoanOutputDatum) = loanOutput.datum
    expect loanOutputDatum: ActiveDatum = rawLoanOutputDatum
    loanOutputDatum == loanInputDatum
  }

  let isLoanOutputValid = and {
      isAddressValid,
      isValueValid,
      isDatumValid,
    }

  (isLoanOutputValid, remainingOutputs)
}

fn is_continuing_address_valid(
  inputAddress: Address,
  outputAddress: Address,
  isCIP113: Bool,
) -> Bool {
  let inputPaymentCredential = inputAddress.payment_credential
  let inputStakeCredential = inputAddress.stake_credential
  let outputPaymentCredential = outputAddress.payment_credential
  let outputStakeCredential = outputAddress.stake_credential
  and {
    outputPaymentCredential == inputPaymentCredential,
    or {
      isCIP113,
      outputStakeCredential == inputStakeCredential,
    },
  }
}

fn validate_recast_loan_output(
  outputs: List<Output>,
  loanPolicyId: PolicyId,
  loanIdTokenName: AssetName,
  loanInputAddress: Address,
  loanInputValue: Value,
  loanInputDatum: ActiveDatum,
  principalPaid: Int,
  isCIP113: Bool,
) -> (Bool, List<Output>, Value) {
  let debtAfterRecasting =
    get_remaining_debt(
      loanInputDatum.commonData.repaymentMode,
      loanInputDatum.principalAmount,
      loanInputDatum.principalDivider,
      loanInputDatum.commonData.interestRate,
      loanInputDatum.commonData.totalInstallments,
      loanInputDatum.repaidInstallments,
    ) - principalPaid

  if debtAfterRecasting == 0 {
    (True, outputs, assets.from_asset(loanPolicyId, loanIdTokenName, -1))
  } else if debtAfterRecasting < 0 {
    (False, outputs, assets.zero)
  } else {
    expect [loanOutput, ..remainingOutputs] =
      list.drop_while(
        outputs,
        fn(output) { !is_output_to_sc(output, loanPolicyId) },
      )

    let isAddressValid =
      is_continuing_address_valid(
        loanInputAddress,
        loanOutput.address,
        isCIP113,
      )

    let isValueValid = and {
        assets.quantity_of(loanOutput.value, loanPolicyId, loanIdTokenName) == 1,
        loanOutput.value == loanInputValue,
      }

    let isDatumValid = {
      expect InlineDatum(rawLoanOutputDatum) = loanOutput.datum
      expect loanOutputDatum: ActiveDatum = rawLoanOutputDatum

      let expectedLoanOutputDatum =
        ActiveDatum {
          ..loanInputDatum,
          principalAmount: loanInputDatum.principalAmount - principalPaid,
          doneRecasts: loanInputDatum.doneRecasts + 1,
        }
      loanOutputDatum == expectedLoanOutputDatum
    }

    let isLoanOutputValid = and {
        isAddressValid,
        isValueValid,
        isDatumValid,
      }

    (isLoanOutputValid, remainingOutputs, assets.zero)
  }
}

fn validate_output_to_dutch_auction(
  activeLoanInput: Input,
  borrower_bond_input: Input,
  dutchAuctionOutput: Output,
  validTo: Int,
  lenderAuthHash: ByteArray,
  lenderAddress: Address,
  principalAsset: Asset,
  remainingDebt: Int,
  config: ConfigDatum,
) {
  expect InlineDatum(outputDatum) = dutchAuctionOutput.datum
  expect parsedDatum: DutchAuctionDatum = outputDatum
  let borrowerAddress = borrower_bond_input.output.address

  let newDatum =
    DutchAuctionDatum {
      ownerAuthHash: lenderAuthHash,
      ownerAddress: lenderAddress,
      currency: principalAsset,
      startingPrice: remainingDebt * config.dutchAuctionStartingIncreasePerMille / 1000,
      loweringAmount: config.dutchAuctionLoweringAmount,
      loweringFrequency: config.dutchAuctionLoweringFrequency,
      minPriceToCancel: config.dutchAuctionMinPriceToCancel,
      startDate: validTo,
      borrowerAddress: Some(borrowerAddress),
      debtAmount: remainingDebt,
    }
  let isDatumCorrect = parsedDatum == newDatum
  and {
    is_output_to_sc(dutchAuctionOutput, dutchAuctionScriptHash),
    activeLoanInput.output.value == dutchAuctionOutput.value,
    isDatumCorrect,
  }
}
