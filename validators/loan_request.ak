use aiken/bytearray
use aiken/hash.{sha2_256}
use aiken/interval.{Finite, Interval}
use aiken/list.{length}
use aiken/time.{PosixTime}
use aiken/transaction.{InlineDatum, Output, ScriptContext, Spend, Transaction}
use aiken/transaction/credential.{Address}
use aiken/transaction/value.{
  AssetName, Value, flatten, quantity_of, without_lovelace,
}
use types.{ActiveDatum, Asset}
use utils.{
  get_inputs_from_sc, get_outputs_to_sc, get_own_hash, must_be_signed_by,
  only_one_sc_used, tokens_sent_to_lender_and_borrower,
  validity_range_within_an_hour,
}

type Datum {
  borrowerAddress: Address,
  loan: Asset,
  loanAmnt: Int,
  interest: Asset,
  interestAmnt: Int,
  collateral: Value,
  loanDuration: Int,
  requestExpiration: Int,
  //Min value is 1
  totalInstallments: Int,
}

type Redeemer {
  //Borrower action
  CancelLoanRequest
  //Lender action
  Lend {
    //The current input (that is being validated) index in the filtered list of tx inputs that come from this SC.
    //This is also the same output index for the active loan in the filtered list of tx output that go to Active Loan SC.
    //This will also be the absolute index of the output that goes to the borrower address.
    currentLoanRequestInputIndex: Int,
    //Lender wants his bond NFT to be sent to this address
    lenderAddress: Address,
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
          CancelLoanRequest ->
            must_be_signed_by(ctx.transaction, datum.borrowerAddress)
          Lend(currentLoanRequestInputIndex, lenderAddress) -> {
            //borrower action
            let inputUtxoId =
              sha2_256(
                bytearray.push(
                  currentInput.transaction_id.hash,
                  currentInput.output_index,
                ),
              )
            expect Some(actualLoanRequestInput) =
              list.at(
                get_inputs_from_sc(ctx.transaction.inputs, ownScriptHash),
                currentLoanRequestInputIndex,
              )
            expect Some(outputToActiveLoan) =
              list.at(
                get_outputs_to_sc(ctx.transaction.outputs, activeLoanSCHash),
                currentLoanRequestInputIndex,
              )
            expect Some(outputToBorrower) =
              list.at(ctx.transaction.outputs, currentLoanRequestInputIndex)
            and {
              //ensure that the inputs index passed in redeemer corresponds to this input being validated
              currentInput == actualLoanRequestInput.output_reference,
              only_one_sc_used(ctx.transaction.inputs, ownScriptHash),
              validity_range_within_an_hour(ctx.transaction),
              validate_request_expiration(
                ctx.transaction,
                datum.requestExpiration,
              ),
              tokens_sent_to_lender_and_borrower(
                ctx.transaction.outputs,
                inputUtxoId,
                lenderAddress,
                datum.borrowerAddress,
                borrowersNftCs,
                lendersNftCs,
              ),
              validate_output_to_active_loan(
                outputToActiveLoan,
                datum,
                inputUtxoId,
                ctx.transaction.validity_range,
              ),
              validate_output_to_borrower(
                outputToBorrower,
                datum.borrowerAddress,
                datum.loan,
                datum.loanAmnt,
              ),
            }
          }
        }
      _ -> False
    }
  }
}

fn validate_request_expiration(tx: Transaction, requestExpiration: Int) {
  when tx.validity_range.upper_bound.bound_type is {
    Finite(end) -> end < requestExpiration
    _ -> False
  }
}

fn validate_output_to_active_loan(
  output: Output,
  datum: Datum,
  assetName: AssetName,
  txValidityRange: Interval<PosixTime>,
) {
  when txValidityRange.upper_bound.bound_type is {
    Finite(end) -> {
      expect InlineDatum(outputDatum) = output.datum
      expect parsedDatum: ActiveDatum = outputDatum

      let containsCorrectCollateral =
        datum.collateral == without_lovelace(output.value)

      let newDatum =
        ActiveDatum {
          borrowerNFT: assetName,
          loan: datum.loan,
          loanAmnt: datum.loanAmnt,
          interest: datum.interest,
          interestAmnt: datum.interestAmnt,
          collateral: datum.collateral,
          loanDuration: datum.loanDuration,
          lenderNFT: assetName,
          lendDate: end,
          totalInstallments: datum.totalInstallments,
          installmentsRepaid: 0,
        }

      let isDatumCorrect = parsedDatum == newDatum

      and {
        containsCorrectCollateral,
        isDatumCorrect,
      }
    }
    //No need for a dos check because we enforce exactly the same collateral
    _ -> False
  }
}

fn validate_output_to_borrower(
  outputToBorrower: Output,
  borrowerAddress: Address,
  loan: Asset,
  loanAmnt: Int,
) {
  let dosProtection = length(flatten(outputToBorrower.value)) <= 21

  //It's max 20 tokens + ada
  and {
    outputToBorrower.address == borrowerAddress,
    quantity_of(outputToBorrower.value, loan.policyId, loan.assetName) == loanAmnt,
    dosProtection,
  }
}
