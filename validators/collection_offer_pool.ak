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
use types.{ActiveDatum, Asset, CollectionAmount}
use utils.{
  get_inputs_from_sc, get_outputs_to_sc, get_own_hash, is_output_to_sc,
  must_be_signed_by, tokens_sent_to_lender_and_borrower,
  validity_range_within_an_hour,
}

type Datum {
  lenderAddress: Address,
  //How much money are currently contained in this pool? It must always be equal to the amount in Value of this utxo
  containedAmount: Int,
  //This is the asset both of the loan and the interest
  loan: Asset,
  //How much can be lent with a loan using a single "collateralOptions" (borrower can ask more using a multiple of the latter)
  maxLoanPerSingleCollateralOption: Int,
  //Per mille of the loan to repay to lender
  interestRate: Int,
  //This pool can cover multiple collections, but only one of them can be chosen for each loan (ie. no mixed bundle loans)
  collateralOptions: List<CollectionAmount>,
  loanDuration: Int,
  offerPoolExpiration: Int,
  totalInstallments: Int,
}

type Redeemer {
  //Lender action
  CancelOfferPool
  //Borrower action
  AcceptOffer {
    //How much the borrower wants to get (if > maxLoanPerSingleCollateralOption then borrower has to lock multiple tokens based on collateralOptions)
    amount: Int,
    //The current input (that is being validated) index in the filtered list of tx inputs that come from this SC.
    //This is also the same output index for the active loan in the filtered list of tx output that go to Active Loan SC.
    //This is also the same output index for the same Pool (if remainingAmount > 0) in the absolute list of tx outputs.
    currentOfferPoolInputIndex: Int,
    //Borrower wants his bond NFT to be sent to this address
    borrowerAddress: Address,
  }
}

validator(
  borrowersNftCs: ByteArray,
  lendersNftCs: ByteArray,
  activeLoanSCHash: ByteArray,
) {
  fn spend(datum: Datum, redeemer: Redeemer, ctx: ScriptContext) -> Bool {
    // we need the contract hash
    let ownScriptHash = get_own_hash(ctx.purpose, ctx.transaction.inputs)

    when ctx.purpose is {
      Spend(currentInput) ->
        when redeemer is {
          CancelOfferPool ->
            must_be_signed_by(ctx.transaction, datum.lenderAddress)
          AcceptOffer(wantedAmount, currentOfferPoolInputIndex, borrowerAddress) -> {
            //borrower action
            let inputUtxoId =
              sha2_256(
                bytearray.push(
                  currentInput.transaction_id.hash,
                  currentInput.output_index,
                ),
              )
            let remainingAmount = datum.containedAmount - wantedAmount
            expect Some(actualOfferPoolInput) =
              list.at(
                get_inputs_from_sc(ctx.transaction.inputs, ownScriptHash),
                currentOfferPoolInputIndex,
              )
            expect Some(outputToActiveLoan) =
              list.at(
                get_outputs_to_sc(ctx.transaction.outputs, activeLoanSCHash),
                currentOfferPoolInputIndex,
              )
            and {
              //ensure that the inputs index passed in redeemer corresponds to this input being validated
              currentInput == actualOfferPoolInput.output_reference,
              wantedAmount > 0,
              validity_range_within_an_hour(ctx.transaction),
              validate_request_expiration(
                ctx.transaction,
                datum.offerPoolExpiration,
              ),
              tokens_sent_to_lender_and_borrower(
                ctx.transaction.outputs,
                inputUtxoId,
                datum.lenderAddress,
                borrowerAddress,
                borrowersNftCs,
                lendersNftCs,
              ),
              when remainingAmount is {
                0 -> True
                amount if amount > 0 -> {
                  expect Some(outputToOfferPool) =
                    list.at(ctx.transaction.outputs, currentOfferPoolInputIndex)
                  validate_output_to_collection_offer(
                    outputToOfferPool,
                    datum,
                    remainingAmount,
                    ownScriptHash,
                  )
                }
                _ -> False
              },
              validate_output_to_active_loan(
                outputToActiveLoan,
                datum,
                inputUtxoId,
                wantedAmount,
                ctx.transaction.validity_range,
              ),
            }
          }
        }
      _ -> False
    }
  }
}

fn validate_request_expiration(tx: Transaction, offerPoolExpiration: Int) {
  when tx.validity_range.upper_bound.bound_type is {
    Finite(end) -> end < offerPoolExpiration
    _ -> False
  }
}

//Expects remainingAmount > 0
fn validate_output_to_collection_offer(
  output: Output,
  datum: Datum,
  remainingAmount: Int,
  ownScriptHash: ByteArray,
) {
  expect InlineDatum(outputDatum) = output.datum
  expect parsedDatum: Datum = outputDatum

  let containsCorrectAmount =
    quantity_of(output.value, datum.loan.policyId, datum.loan.assetName) == remainingAmount

  let newDatum =
    Datum {
      lenderAddress: datum.lenderAddress,
      containedAmount: remainingAmount,
      loan: datum.loan,
      maxLoanPerSingleCollateralOption: datum.maxLoanPerSingleCollateralOption,
      interestRate: datum.interestRate,
      collateralOptions: datum.collateralOptions,
      loanDuration: datum.loanDuration,
      offerPoolExpiration: datum.offerPoolExpiration,
      totalInstallments: datum.totalInstallments,
    }

  let isDatumCorrect = parsedDatum == newDatum

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

fn validate_output_to_active_loan(
  output: Output,
  datum: Datum,
  assetName: AssetName,
  wantedAmount: Int,
  txValidityRange: Interval<PosixTime>,
) {
  when txValidityRange.upper_bound.bound_type is {
    Finite(end) -> {
      expect InlineDatum(outputDatum) = output.datum
      expect parsedDatum: ActiveDatum = outputDatum

      let containsCorrectCollateral =
        value_contains_at_least_1_wanted_collection_with_correct_quantity(
          output.value,
          datum.collateralOptions,
          wantedAmount,
          datum.maxLoanPerSingleCollateralOption,
        )

      let newDatum =
        ActiveDatum {
          borrowerNFT: assetName,
          loan: datum.loan,
          loanAmnt: wantedAmount,
          interest: datum.loan,
          interestAmnt: wantedAmount * datum.interestRate / 1000,
          collateral: without_lovelace(output.value),
          loanDuration: datum.loanDuration,
          lenderNFT: assetName,
          lendDate: end,
          totalInstallments: datum.totalInstallments,
          installmentsRepaid: 0,
        }

      let isDatumCorrect = parsedDatum == newDatum

      let dosProtection = length(flatten(output.value)) <= 21

      //It's max 20 tokens + ada
      and {
        containsCorrectCollateral,
        isDatumCorrect,
        dosProtection,
      }
    }
    _ -> False
  }
}

fn value_contains_at_least_1_wanted_collection_with_correct_quantity(
  value: Value,
  collateralOptions: List<CollectionAmount>,
  wantedAmount: Int,
  maxLoanPerSingleCollateralOption: Int,
) {
  //We want to count the number of tokens of the same policy
  //value = Map<(ply1, tns1), (ply2, tns2), (ply3, tns3)>
  //tns1 = Map<(tn1, 1), (tn2, 4), (tn3, 3)]> -> 8
  //policiesTokens = [(ply1, 8), (ply2, 3), (ply3, 2)]
  let policiesTokens =
    dict.to_list(
      dict.map(
        to_dict(value),
        fn(_k, v) { dict.foldr(v, 0, fn(_k2, v2, total) { v2 + total }) },
      ),
    )

  list.any(
    collateralOptions,
    fn(collectionAmount) {
      list.any(
        policiesTokens,
        fn(token) {
          //if borrower asks more than maxLoanPerSingleCollateralOption he needs to put as collateral a multiple of the lender wantedCollectionAmount
          let multiplier =
            ( wantedAmount - 1 ) / maxLoanPerSingleCollateralOption + 1
          and {
            token.1st == collectionAmount.policyId,
            token.2nd == collectionAmount.amount * multiplier,
          }
        },
      )
    },
  )
}
