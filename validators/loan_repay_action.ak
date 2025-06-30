use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use cardano/address.{Address, Credential, Inline, Script, StakeCredential}
use cardano/assets.{PolicyId, flatten, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use fluidtokens/constants
use fluidtokens/finance.{
  get_next_installment_amount, get_remaining_debt, is_repayment_late,
}
use fluidtokens/types/config.{ConfigDatum}
use fluidtokens/types/general.{Asset}
use fluidtokens/types/loan.{
  LoanDatum, LoanRepayActionWithdrawRedeemer, LoanRepaymentData,
} as l
use fluidtokens/types/pool.{CommonData, PerpetualLoan}
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
    redeemer: LoanRepayActionWithdrawRedeemer,
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
        let inputAction = safe_list_at(redeemer.actionsForEachInput, index)

        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: LoanDatum = inputDatum

        expect Some(interestRateAsRational) =
          rational.new(datum.commonData.interestRate, 10000)

        check_repay(
          self,
          credential,
          input,
          inputAction.borrowerBondOutputIndex,
          inputAction.lenderBondRefInputIndex,
          index,
          config,
          datum,
          config.loanPolicyId,
          inputAction.loanId,
          interestRateAsRational,
          inputAction.isFinalRepayment,
        )
      },
    )
  }

  else(_) {
    fail
  }
}

fn check_repay(
  self: Transaction,
  credential: Credential,
  input: Input,
  borrowerBondOutputIndex: Int,
  lenderBondRefInputIndex: Int,
  loanInputIndex: Int,
  config: ConfigDatum,
  datum: LoanDatum,
  loanPolicyId: PolicyId,
  loanId: ByteArray,
  interestRateAsRational: rational.Rational,
  isFinalRepayment: Bool,
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

  let isPerpetualLoan =
    when datum.commonData.repaymentMode is {
      PerpetualLoan { .. } -> True
      _ -> False
    }

  let isRepaymentLate =
    is_repayment_late(
      isPerpetualLoan,
      validTo,
      datum.lendDate,
      datum.commonData.initialGracePeriod,
      datum.repaidInstallments,
      datum.commonData.installmentPeriod,
      datum.commonData.repaymentTimeWindow,
    )
  let nextRepaymentAmount =
    if isPerpetualLoan && (
      isFinalRepayment || datum.commonData.installmentPeriod == 0
    ) {
      get_remaining_debt(
        datum.commonData.repaymentMode,
        rational.from_int(datum.principalAmount),
        interestRateAsRational,
        datum.totalInstallments,
        datum.repaidInstallments,
        datum.commonData.installmentPeriod,
        datum.commonData.initialGracePeriod,
        validTo - datum.lendDate,
      )
    } else {
      get_next_installment_amount(
        datum.commonData.repaymentMode,
        rational.from_int(datum.principalAmount),
        interestRateAsRational,
        datum.totalInstallments,
        datum.repaidInstallments,
        datum.commonData.installmentPeriod,
        datum.commonData.initialGracePeriod,
        isRepaymentLate,
        datum.commonData.penaltyFeeForLateRepayment,
      )
    }
  and {
    quantity_of(input.output.value, loanPolicyId, loanId) == 1,
    is_nft_in_output(config.borrowerBondPolicyId, loanId, borrowerBondOutput),
    validate_repayment_output(
      loanInputOutputReference: input.output_reference,
      repaymentOutput: repaymentOutput,
      lenderBondAsset: Asset {
        policyId: config.lenderBondPolicyId,
        assetName: loanId,
      },
      repaymentAsset: datum.commonData.principalAsset,
      repaymentAmount: nextRepaymentAmount,
      action: constants.repayment_action_installment,
      extra_data: LoanRepaymentData {
        loanId,
        principalAmount: datum.principalAmount,
        interestRate: datum.commonData.interestRate,
        repaidInstallments: datum.repaidInstallments + 1,
        totalInstallments: datum.totalInstallments,
        repaymentMode: datum.commonData.repaymentMode,
      },
      repaymentReceipts: datum.commonData.repaymentReceipts,
      repaymentPolicyId: config.repaymentPolicyId,
    ),
    or {
      and {
        if isPerpetualLoan {
          isFinalRepayment || datum.commonData.installmentPeriod == 0
        } else {
          datum.repaidInstallments == datum.totalInstallments - 1
        },
        quantity_of(self.mint, loanPolicyId, loanId) == -1,
      },
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
        validate_eventual_output_to_loan_for_repayment(
          loanOutput,
          datum,
          input.output.value == loanOutput.value,
          input.output.address.stake_credential,
          config.loanSpendScriptHash,
        )
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

fn validate_eventual_output_to_loan_for_repayment(
  loanOutput: Output,
  datum: LoanDatum,
  outputValueSameOfInputValue: Bool,
  prevStakeCredential: Option<StakeCredential>,
  loanSpendScriptHash: ByteArray,
) {
  expect InlineDatum(outputDatum) = loanOutput.datum
  expect parsedDatum: LoanDatum = outputDatum

  let newDatum =
    LoanDatum {
      commonData: datum.commonData,
      totalInstallments: datum.totalInstallments,
      originId: datum.originId,
      collateral: datum.collateral,
      principalAmount: datum.principalAmount,
      lendDate: datum.lendDate,
      repaidInstallments: datum.repaidInstallments + 1,
      doneRecasts: datum.doneRecasts,
    }
  let isDatumCorrect = parsedDatum == newDatum

  let correctDestination =
    if is_output_to_spend_validator(loanOutput, loanSpendScriptHash) {
      loanOutput.address.stake_credential == prevStakeCredential
    } else {
      //outputs have been already filtered at the beginning
      True
    }
  and {
    correctDestination,
    isDatumCorrect,
    //loanNFT is already included in the value
    outputValueSameOfInputValue,
  }
}
