use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use aiken/math.{pow}
use cardano/address.{Address, Credential, Inline, Script}
use cardano/assets.{PolicyId, flatten, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use fluidtokens/constants
use fluidtokens/types/config.{ConfigDatum}
use fluidtokens/types/general.{Asset}
use fluidtokens/types/loan.{LoanDatum, LoanRecastActionWithdrawRedeemer} as l
use fluidtokens/types/pool.{
  CommonData, InterestOnRemainingPrincipal, PerpetualLoan,
}
use fluidtokens/types/repayment.{RepaymentDatum, RepaymentDatumWithToken}
use fluidtokens/utils.{
  is_nft_in_output, is_output_to_spend_validator, safe_list_at,
}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator loan_claim_action(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  withdraw(
    redeemer: LoanRecastActionWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    let config =
      utils.get_config(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let loanInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(config.loanSpendScriptHash),
        credential,
        config.smartTokensSpendScriptHash,
      )

    //As we loop through the inputs we DO NOT need to ensure that the number of actions is equal to the number of inputs
    list.indexed_foldr(
      loanInputs,
      True,
      fn(index, input, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        let inputAction = safe_list_at(redeemer.action, index)

        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: LoanDatum = inputDatum

        check_recast(
          self,
          credential,
          input,
          inputAction.borrowerBondOutputIndex,
          inputAction.lenderBondRefInputIndex,
          index,
          config,
          datum,
          inputAction.principalPaid,
          config.loanPolicyId,
          inputAction.loanId,
        )
      },
    )
  }

  else(_) {
    fail
  }
}

fn check_recast(
  self: Transaction,
  credential: Credential,
  input: Input,
  borrowerBondOutputIndex: Int,
  lenderBondRefInputIndex: Int,
  loanInputIndex: Int,
  config: ConfigDatum,
  datum: LoanDatum,
  principalPaid: Int,
  loanPolicyId: PolicyId,
  loanId: ByteArray,
) {
  expect Finite(validTo) = self.validity_range.upper_bound.bound_type
  let borrowerBondOutput = safe_list_at(self.outputs, borrowerBondOutputIndex)
  let lenderBondAddress =
    safe_list_at(self.reference_inputs, lenderBondRefInputIndex).output.address
  expect Some(Inline(lenderBondStakeCredential)) =
    lenderBondAddress.stake_credential
  expect Some(repaymentOutput) =
    list.at(
      get_outputs_to_smart_credential(
        self.outputs,
        lenderBondAddress.payment_credential,
        lenderBondStakeCredential,
        config.smartTokensSpendScriptHash,
      ),
      loanInputIndex,
    )
  let periodToLatestPaidInstallment =
    datum.repaidInstallments * datum.commonData.installmentPeriod
  let timePassedSinceLastRepaidInstallment =
    validTo - (
      datum.lendDate + (
        datum.commonData.initialGracePeriod + periodToLatestPaidInstallment
      ) * constants.hour_to_millis
    )
  let dueInstallments =
    timePassedSinceLastRepaidInstallment / (
      datum.commonData.installmentPeriod * constants.hour_to_millis
    )

  let principalAfterRecasting =
    when datum.commonData.repaymentMode is {
      InterestOnRemainingPrincipal { .. } -> {
        //Formula is: P * (1 - ((1+r)^n - (1+r)^k)/((1+r)^n - 1))
        //where P = principal amount, r = interest rate per installment, n = total installments and k = repaid installments
        let interestPerInstallment =
          datum.commonData.interestRate / datum.totalInstallments
        let onePlusRToN =
          pow(1 + interestPerInstallment, datum.totalInstallments)
        let onePlusRToK =
          pow(1 + interestPerInstallment, datum.repaidInstallments)
        let principalPaidSoFar =
          datum.principalAmount * (
            1 - ( onePlusRToN - onePlusRToK ) / ( onePlusRToN - 1 )
          )
        datum.principalAmount - principalPaidSoFar - principalPaid
      }
      _ -> datum.principalAmount - principalPaid
    }

  and {
    principalPaid > 0,
    quantity_of(input.output.value, loanPolicyId, loanId) == 1,
    is_nft_in_output(config.borrowerBondPolicyId, loanId, borrowerBondOutput),
    //A recast is permitted only if the loan has installments
    datum.commonData.installmentPeriod > 0,
    //A recast is permitted only when all due installments + 1 are paid, otherwise the borrower avoids paying what is due
    datum.repaidInstallments >= dueInstallments + 1,
    //A recast must be within the number of recasts allowed
    when datum.commonData.repaymentMode is {
      InterestOnRemainingPrincipal { max_possible_recasts } ->
        datum.doneRecasts < max_possible_recasts
      PerpetualLoan { max_possible_recasts, .. } ->
        datum.doneRecasts < max_possible_recasts
      _ -> fail
    },
    validate_repayment_output(
      loanInputOutputReference: input.output_reference,
      repaymentOutput: repaymentOutput,
      lenderBondAsset: Asset {
        policyId: config.lenderBondPolicyId,
        assetName: loanId,
      },
      repaymentAsset: datum.commonData.principalAsset,
      repaymentAmount: principalPaid,
      action: constants.repayment_action_recast,
      extra_data: loanId,
      repaymentReceipts: datum.commonData.repaymentReceipts,
      repaymentPolicyId: config.repaymentPolicyId,
    ),
    or {
      and {
        //If principal becomes 0, then the loan is closed (there can't be outstanding interest to pay)
        principalAfterRecasting == 0,
        quantity_of(self.mint, loanPolicyId, loanId) == -1,
      },
      and {
        principalAfterRecasting > 0,
        //Loan output is correct
        {
          let loanOutput =
            safe_list_at(
              get_outputs_to_smart_credential(
                self.outputs,
                Script(config.loanSpendScriptHash),
                credential,
                config.smartTokensSpendScriptHash,
              ),
              loanInputIndex,
            )
          expect InlineDatum(outputDatum) = loanOutput.datum
          expect parsedDatum: LoanDatum = outputDatum
          let newLoanExpectedDatum =
            when datum.commonData.repaymentMode is {
              InterestOnRemainingPrincipal { .. } -> {
                let newTotalInstallments =
                  datum.totalInstallments - datum.repaidInstallments
                let newRepaidIntstallments = 0

                LoanDatum {
                  commonData: datum.commonData,
                  totalInstallments: newTotalInstallments,
                  originId: datum.originId,
                  collateral: datum.collateral,
                  principalAmount: principalAfterRecasting,
                  lendDate: datum.lendDate,
                  repaidInstallments: newRepaidIntstallments,
                  doneRecasts: datum.doneRecasts + 1,
                }
              }
              _ ->
                LoanDatum {
                  commonData: datum.commonData,
                  totalInstallments: datum.totalInstallments,
                  originId: datum.originId,
                  collateral: datum.collateral,
                  principalAmount: principalAfterRecasting,
                  lendDate: datum.lendDate,
                  repaidInstallments: datum.repaidInstallments,
                  doneRecasts: datum.doneRecasts + 1,
                }
            }
          let correctDestination =
            if is_output_to_spend_validator(
              loanOutput,
              config.loanSpendScriptHash,
            ) {
              loanOutput.address.stake_credential == input.output.address.stake_credential
            } else {
              //outputs have been already filtered at the beginning
              True
            }
          and {
            correctDestination,
            parsedDatum == newLoanExpectedDatum,
            //loanNFT is already included in the value
            input.output.value == loanOutput.value,
          }
        },
      },
    },
  }
}

fn validate_repayment_output(
  loanInputOutputReference: OutputReference,
  repaymentOutput: Output,
  lenderBondAsset: Asset,
  repaymentAsset: Asset,
  repaymentAmount: Int,
  action: ByteArray,
  extra_data: Data,
  repaymentReceipts: Bool,
  repaymentPolicyId: ByteArray,
) {
  expect InlineDatum(outputDatum) = repaymentOutput.datum
  expect parsedDatum: RepaymentDatum = outputDatum
  let newDatum =
    RepaymentDatumWithToken {
      inputOutputReference: loanInputOutputReference,
      action,
      data: extra_data,
      ownerAsset: lenderBondAsset,
    }
  let containsCorrectAmount =
    quantity_of(
      repaymentOutput.value,
      repaymentAsset.policyId,
      repaymentAsset.assetName,
    ) >= repaymentAmount
  let receiptCondition =
    repaymentReceipts == False || quantity_of(
      repaymentOutput.value,
      repaymentPolicyId,
      utils.hash_output_ref(loanInputOutputReference),
    ) == 1

  let isDatumCorrect = parsedDatum == newDatum
  let receiptAssetCount =
    if receiptCondition {
      1
    } else {
      0
    }
  let dosProtection =
    if repaymentAsset.policyId == "" {
      length(flatten(repaymentOutput.value)) == 1 + receiptAssetCount
    } else {
      length(flatten(repaymentOutput.value)) == 2 + receiptAssetCount
    }
  and {
    //No staking check here
    isDatumCorrect,
    receiptCondition,
    containsCorrectAmount,
    dosProtection,
  }
}
