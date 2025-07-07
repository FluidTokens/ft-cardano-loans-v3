use aiken/builtin
use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use cardano/address.{Address, Credential, Script, StakeCredential}
use cardano/assets.{Value, add, flatten, quantity_of, without_lovelace}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use fluidtokens/finance.{can_liquidate}
use fluidtokens/oracle.{retrieve_oracle_data}
use fluidtokens/types/general.{Asset, CollateralAsset, Liquidation}
use fluidtokens/types/loan.{
  LoanChangeCollateralActionWithdrawRedeemer, LoanDatum,
} as l
use fluidtokens/utils.{
  asset_names_number_of_policy_id, is_nft_in_output,
  is_output_to_spend_validator, quantity_of_policy_id, safe_list_at,
  value_without_policy_id_as_list,
}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator loan_change_collateral_action(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  withdraw(
    redeemer: LoanChangeCollateralActionWithdrawRedeemer,
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
    let loanPolicyId = builtin.un_b_data(utils.safe_list_at(config, 2))
    let borrowerBondPolicyId = builtin.un_b_data(utils.safe_list_at(config, 4))
    let loanInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(loanSpendScriptHash),
        Script(loanPolicyId),
        smartTokensSpendScriptHash,
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

        when datum.liquidationMode is {
          Liquidation { lTV, lTVDivider, .. } -> {
            expect (Finite(validFrom), Finite(validTo)) =
              (
                self.validity_range.lower_bound.bound_type,
                self.validity_range.upper_bound.bound_type,
              )
            let borrowerBondOutput =
              safe_list_at(self.outputs, inputAction.borrowerBondOutputIndex)
            let loanOutput =
              utils.safe_list_at(
                get_outputs_to_smart_credential(
                  self.outputs,
                  Script(loanSpendScriptHash),
                  Script(loanPolicyId),
                  smartTokensSpendScriptHash,
                ),
                index,
              )
            expect Some(ltvAsRational) = rational.new(lTV, lTVDivider)
            let collateralOracleRefInput =
              safe_list_at(
                self.reference_inputs,
                inputAction.collateralOracleRefInputIndex,
              )
            expect Some(collateralOraclePriceFeed) =
              retrieve_oracle_data(
                collateralOracleRefInput.output.address.payment_credential,
                collateralOracleRefInput.output.value,
                self.redeemers,
                validFrom,
                validTo,
                datum.collateral.oracleTokenAsset.policyId,
                datum.collateral.oracleTokenAsset.assetName,
                datum.collateral.policyId,
                datum.collateral.maybeAssetName,
              )
            let principalOracleRefInput =
              safe_list_at(
                self.reference_inputs,
                inputAction.principalOracleRefInputIndex,
              )
            expect Some(principalOraclePriceFeed) =
              retrieve_oracle_data(
                principalOracleRefInput.output.address.payment_credential,
                principalOracleRefInput.output.value,
                self.redeemers,
                validFrom,
                validTo,
                datum.principalOracleAsset.policyId,
                datum.principalOracleAsset.assetName,
                datum.principalAsset.policyId,
                Some(datum.principalAsset.assetName),
              )
            and {
              quantity_of(input.output.value, loanPolicyId, inputAction.loanId) == 1,
              is_nft_in_output(
                borrowerBondPolicyId,
                inputAction.loanId,
                borrowerBondOutput,
              ),
              can_liquidate(
                rational.from_int(datum.principalAmount),
                rational.from_int(inputAction.newCollateralAmount),
                ltvAsRational,
                principalOraclePriceFeed,
                collateralOraclePriceFeed,
              ) == False,
              validate_output_to_loan_for_changing_collateral(
                loanOutput,
                datum,
                inputAction.newCollateralAmount,
                input.output.value,
                input.output.address.stake_credential,
                loanSpendScriptHash,
              ),
            }
          }
          _ -> False
        }
      },
    )
  }

  else(_) {
    fail
  }
}

fn validate_output_to_loan_for_changing_collateral(
  loanOutput: Output,
  datum: LoanDatum,
  newCollateralAmount: Int,
  loanValue: Value,
  prevStakeCredential: Option<StakeCredential>,
  loanSpendScriptHash: ByteArray,
) {
  expect InlineDatum(outputDatum) = loanOutput.datum

  let correctValue =
    if datum.collateral.maybeAssetName == None {
      let newCollateralTokens =
        quantity_of_policy_id(loanOutput.value, datum.collateral.policyId)

      let newCollateralAssetNames =
        asset_names_number_of_policy_id(
          loanOutput.value,
          datum.collateral.policyId,
        )
      //The Value must be the same as before except for the quantity of tokens with same collateral's policyId
      let oldValueWithoutPolicyId =
        value_without_policy_id_as_list(
          without_lovelace(loanValue),
          datum.collateral.policyId,
        )
      let sameValueWithoutCollateralTokens =
        oldValueWithoutPolicyId == value_without_policy_id_as_list(
          without_lovelace(loanOutput.value),
          datum.collateral.policyId,
        )
      let dosProtection =
        length(flatten(loanOutput.value)) == length(oldValueWithoutPolicyId) + newCollateralAssetNames + 1
      and {
        sameValueWithoutCollateralTokens,
        newCollateralTokens == newCollateralAmount,
        dosProtection,
      }
    } else {
      expect Some(assetName) = datum.collateral.maybeAssetName
      //As there is no simple way to forcefully set a token amount in a Value, 
      //we substract the current amount (resulting it as 0) and add the new one
      let expectedValue =
        add(
          loanValue,
          datum.collateral.policyId,
          assetName,
          -quantity_of(loanValue, datum.collateral.policyId, assetName) + newCollateralAmount,
        )
      loanOutput.value == expectedValue
    }

  let correctDestination =
    if is_output_to_spend_validator(loanOutput, loanSpendScriptHash) {
      loanOutput.address.stake_credential == prevStakeCredential
    } else {
      //outputs have been already filtered at the beginning
      True
    }

  and {
    correctDestination,
    builtin.equals_data(outputDatum, datum),
    //loanNFT is already included in the value
    correctValue,
  }
}
