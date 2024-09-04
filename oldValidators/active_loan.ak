use aiken/interval.{Finite, Interval}
use aiken/list.{length}
use aiken/time.{PosixTime}
use aiken/transaction.{InlineDatum, Input, Output, ScriptContext, Spend}
use aiken/transaction/value.{flatten, quantity_of, without_lovelace}
use types.{ActiveDatum, RepaymentDatum}
use utils.{
  get_inputs_from_sc, get_outputs_to_sc, get_own_hash, is_nft_spent,
  is_output_to_sc,
}

type Redeemer {
  //Lender action
  Claim {
    //This is the absolute input index that contains the lender bond
    bondInputIndex: Int,
  }
  //Borrower action
  Repay {
    //The current input (that is being validated) index in the filtered list of tx inputs that come from this SC.
    //This is also the same output index for the repayment in the filtered list of tx output that go to Repayment SC.
    //This is also the same output index for the eventual same Active Loan in the absolute list of tx outputs.
    currentActiveLoanInputIndex: Int,
    //This is the absolute input index that contains the borrower bond
    bondInputIndex: Int,
    //How many installments are being repaid by this tx for this Active Loan?
    installmentsRepaid: Int,
  }
}

validator(
  borrowersNftCs: ByteArray,
  lendersNftCs: ByteArray,
  repaymentSCHash: ByteArray,
) {
  fn spend(datum: ActiveDatum, redeemer: Redeemer, ctx: ScriptContext) -> Bool {
    // we need the contract hash
    let ownScriptHash = get_own_hash(ctx.purpose, ctx.transaction.inputs)

    when ctx.purpose is {
      Spend(currentInput) ->
        when redeemer is {
          Claim(bondInputIndex) -> {
            expect Some(actualBondInput) =
              list.at(ctx.transaction.inputs, bondInputIndex)
            and {
              is_it_after_deadline(
                ctx.transaction.validity_range,
                datum.lendDate,
                datum.installmentsRepaid,
                datum.totalInstallments,
                datum.loanDuration,
              ),
              is_nft_spent(lendersNftCs, datum.lenderNFT, actualBondInput),
            }
          }
          Repay(currentActiveLoanInputIndex, bondInputIndex, installmentsRepaid) -> {
            expect Some(actualActiveLoanInput) =
              list.at(
                get_inputs_from_sc(ctx.transaction.inputs, ownScriptHash),
                currentActiveLoanInputIndex,
              )
            expect Some(actualBondInput) =
              list.at(ctx.transaction.inputs, bondInputIndex)
            and {
              currentInput == actualActiveLoanInput.output_reference,
              installmentsRepaid > 0,
              validate_output_to_repayment_and_to_eventual_active_loan_and_used_borrower_nft(
                ctx.transaction.outputs,
                ownScriptHash,
                currentActiveLoanInputIndex,
                datum,
                installmentsRepaid,
                actualBondInput,
                repaymentSCHash,
                borrowersNftCs,
              ),
            }
          }
        }
      _ -> False
    }
  }
}

fn is_it_after_deadline(
  txValidityRange: Interval<PosixTime>,
  lendDate: Int,
  installmentsRepaid: Int,
  totalInstallments: Int,
  loanDuration: Int,
) {
  when txValidityRange.lower_bound.bound_type is {
    Finite(start) ->
      start > lendDate + relative_max_time_for_next_installment(
        installmentsRepaid,
        totalInstallments,
        loanDuration,
      )
    _ -> False
  }
}

fn relative_max_time_for_next_installment(
  installmentsRepaid: Int,
  totalInstallments: Int,
  loanDuration: Int,
) {
  ( installmentsRepaid + 1 ) * loanDuration / totalInstallments
}

fn validate_output_to_repayment_and_to_eventual_active_loan_and_used_borrower_nft(
  outputs: List<Output>,
  ownScriptHash: ByteArray,
  currentActiveLoanInputIndex: Int,
  datum: ActiveDatum,
  installmentsJustRepaid: Int,
  bondInput: Input,
  repaymentSCHash: ByteArray,
  borrowersNftCs: ByteArray,
) {
  expect Some(repaymentOutput) =
    list.at(
      get_outputs_to_sc(outputs, repaymentSCHash),
      currentActiveLoanInputIndex,
    )

  let isFullRepayment =
    datum.installmentsRepaid + installmentsJustRepaid == datum.totalInstallments

  if isFullRepayment {
    //Eventual partial repayments + full repayment
    and {
      validate_output_to_repayment(
        repaymentOutput,
        datum,
        installmentsJustRepaid,
        True,
      ),
      is_nft_spent(borrowersNftCs, datum.borrowerNFT, bondInput),
    }
  } else {
    //Partial repayments
    expect Some(activeLoanOutput) =
      list.at(outputs, currentActiveLoanInputIndex)
    and {
      is_output_to_sc(activeLoanOutput, ownScriptHash),
      validate_output_to_active_loan(
        activeLoanOutput,
        datum,
        installmentsJustRepaid,
      ),
      validate_output_to_repayment(
        repaymentOutput,
        datum,
        installmentsJustRepaid,
        False,
      ),
      is_nft_spent(borrowersNftCs, datum.borrowerNFT, bondInput),
    }
  }
}

fn validate_output_to_repayment(
  repaymentOutput: Output,
  datum: ActiveDatum,
  installmentsJustRepaid: Int,
  isFullRepayment: Bool,
) {
  let singleInstallmentLoanAmount = datum.loanAmnt / datum.totalInstallments
  let singleInstallmentInterestAmount =
    datum.interestAmnt / datum.totalInstallments

  let finalInstallmentLoanAmount =
    datum.loanAmnt - singleInstallmentLoanAmount * (
      datum.totalInstallments - 1
    )
  let finalInstallmentInterestAmount =
    datum.interestAmnt - singleInstallmentInterestAmount * (
      datum.totalInstallments - 1
    )

  //Remember that last installment amount is anything that is left to be paid!
  let theoricalLoanAmountRepaid =
    when isFullRepayment is {
      True ->
        ( installmentsJustRepaid - 1 ) * singleInstallmentLoanAmount + finalInstallmentLoanAmount
      False -> installmentsJustRepaid * singleInstallmentLoanAmount
    }

  let theoricalInterestAmountRepaid =
    when isFullRepayment is {
      True ->
        ( installmentsJustRepaid - 1 ) * singleInstallmentInterestAmount + finalInstallmentInterestAmount
      False -> installmentsJustRepaid * singleInstallmentInterestAmount
    }

  //Check that the quantity in the Repayment output corresponds to the installments he said he is repaying (installmentsJustRepaid)
  let correctLoanAndInterestAmountsInRepaymentOutput =
    if datum.loan == datum.interest {
      quantity_of(
        repaymentOutput.value,
        datum.loan.policyId,
        datum.loan.assetName,
      ) >= theoricalLoanAmountRepaid + theoricalInterestAmountRepaid
    } else {
      and {
        quantity_of(
          repaymentOutput.value,
          datum.loan.policyId,
          datum.loan.assetName,
        ) >= theoricalLoanAmountRepaid,
        quantity_of(
          repaymentOutput.value,
          datum.interest.policyId,
          datum.interest.assetName,
        ) >= theoricalInterestAmountRepaid,
      }
    }

  expect InlineDatum(outputDatum) = repaymentOutput.datum
  expect parsedDatum: RepaymentDatum = outputDatum
  let newDatum =
    RepaymentDatum {
      lenderNFT: datum.lenderNFT,
      installmentsContained: installmentsJustRepaid,
      installmentsPaidSoFar: datum.installmentsRepaid + installmentsJustRepaid,
      isFinalRepayment: isFullRepayment,
    }

  let isDatumCorrect = parsedDatum == newDatum

  let dosProtection = length(flatten(repaymentOutput.value)) <= 3

  and {
    correctLoanAndInterestAmountsInRepaymentOutput,
    isDatumCorrect,
    dosProtection,
  }
}

fn validate_output_to_active_loan(
  activeLoanOutput: Output,
  datum: ActiveDatum,
  installmentsJustRepaid: Int,
) {
  let containsCorrectCollateral =
    datum.collateral == without_lovelace(activeLoanOutput.value)

  expect InlineDatum(outputDatum) = activeLoanOutput.datum
  expect parsedDatum: ActiveDatum = outputDatum

  let newDatum =
    ActiveDatum {
      borrowerNFT: datum.borrowerNFT,
      loan: datum.loan,
      loanAmnt: datum.loanAmnt,
      interest: datum.interest,
      interestAmnt: datum.interestAmnt,
      collateral: datum.collateral,
      loanDuration: datum.loanDuration,
      lenderNFT: datum.lenderNFT,
      lendDate: datum.lendDate,
      totalInstallments: datum.totalInstallments,
      installmentsRepaid: datum.installmentsRepaid + installmentsJustRepaid,
    }

  let isDatumCorrect = parsedDatum == newDatum

  and {
    containsCorrectCollateral,
    isDatumCorrect,
  }
  //No need for a dos check because we enforce exactly the same collateral          
}
