use aiken/builtin
use cardano/address.{Address, Credential, Script}
use cardano/assets.{without_lovelace}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use fluidtokens/constants
use fluidtokens/types/loan.{LoanDatum,
  LoanTransferDebtActionWithdrawRedeemer} as l
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator loan_tranfer_debt_action(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  withdraw(
    redeemer: LoanTransferDebtActionWithdrawRedeemer,
    _credential: Credential,
    self: Transaction,
  ) {
    let config =
      utils.get_config_as_data_list(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let smartTokensSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 0))
    let loanSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 10))
    let loanPolicyId = builtin.un_b_data(utils.safe_list_at(config, 6))
    let loanInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(loanSpendScriptHash),
        Script(loanPolicyId),
        smartTokensSpendScriptHash,
      )

    //As we loop through the inputs we DO NOT need to ensure that the number of actions is equal to the number of inputs
    utils.indexed_all(
      loanInputs,
      fn(index, input) {
        let inputAction = safe_list_at(redeemer.actionsForEachInput, index)

        let loanOutput =
          safe_list_at(
            get_outputs_to_smart_credential(
              self.outputs,
              Script(loanSpendScriptHash),
              Script(loanPolicyId),
              smartTokensSpendScriptHash,
            ),
            index,
          )

        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: LoanDatum = inputDatum

        expect InlineDatum(oDatum) = loanOutput.datum
        expect outputDatum: LoanDatum = oDatum
        let outputDatumIsCorrect =
          outputDatum == LoanDatum {
            doneRecasts: datum.doneRecasts,
            principalAmount: datum.principalAmount,
            lendDate: datum.lendDate,
            repaidInstallments: datum.repaidInstallments,
            interestRate: datum.interestRate,
            totalInstallments: datum.totalInstallments,
            principalAsset: datum.principalAsset,
            principalOracleAsset: datum.principalOracleAsset,
            installmentPeriod: datum.installmentPeriod,
            initialGracePeriod: datum.initialGracePeriod,
            liquidationMode: datum.liquidationMode,
            repaymentMode: datum.repaymentMode,
            repaymentTimeWindow: datum.repaymentTimeWindow,
            penaltyFeeForLateRepayment: datum.penaltyFeeForLateRepayment,
            repaymentReceipts: datum.repaymentReceipts,
            originId: datum.originId,
            collateral: datum.collateral,
            borrowerAuth: inputAction.newAuth,
            permissionedTransferDebtConditionScriptHash: datum.permissionedTransferDebtConditionScriptHash,
          }
        let outputPaymentCredentialUnchanged =
          input.output.address.payment_credential == loanOutput.address.payment_credential
        let outputValueUnchanged =
          if datum.collateral.policyId == "" {
            input.output.value == loanOutput.value
          } else {
            without_lovelace(input.output.value) == without_lovelace(
              loanOutput.value,
            )
          }
        and {
          //Correct withdraw script called
          or {
            datum.permissionedTransferDebtConditionScriptHash == constants.no_permissioned_condition,
            {
              expect Pair(Script(scriptHash), _amnt) =
                safe_list_at(
                  self.withdrawals,
                  inputAction.permissionedConditionWithdrawIndex,
                )

              datum.permissionedTransferDebtConditionScriptHash == scriptHash
            },
          },
          outputDatumIsCorrect,
          //Force the loan utxo to stay in the smart contract, but update staking credential if wanted
          outputPaymentCredentialUnchanged,
          outputValueUnchanged,
        }
      },
    )
  }

  else(_) {
    fail
  }
}
