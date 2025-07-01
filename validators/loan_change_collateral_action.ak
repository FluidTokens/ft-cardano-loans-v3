use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use cardano/address.{Address, Credential, Script, StakeCredential}
use cardano/assets.{PolicyId,
  Value, add, flatten, quantity_of, without_lovelace}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use fluidtokens/finance.{can_liquidate}
use fluidtokens/oracle.{retrieve_oracle_data}
use fluidtokens/types/config.{ConfigDatum}
use fluidtokens/types/general.{Asset, CollateralAsset}
use fluidtokens/types/loan.{
  LoanChangeCollateralActionWithdrawRedeemer, LoanDatum,
} as l
use fluidtokens/types/pool.{CommonData, Liquidation}
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
      utils.get_config(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let loanInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(config.loanSpendScriptHash),
        Script(config.loanPolicyId),
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

        check_change_collateral(
          self,
          input,
          inputAction.borrowerBondOutputIndex,
          index,
          config,
          datum,
          inputAction.principalOracleRefInputIndex,
          inputAction.collateralOracleRefInputIndex,
          inputAction.newCollateralAmount,
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

fn check_change_collateral(
  self: Transaction,
  input: Input,
  borrowerBondOutputIndex: Int,
  loanInputIndex: Int,
  config: ConfigDatum,
  datum: LoanDatum,
  principalOracleRefInputIndex: Int,
  collateralOracleRefInputIndex: Int,
  newCollateralAmount: Int,
  loanPolicyId: PolicyId,
  loanId: ByteArray,
) {
  when datum.commonData.liquidationMode is {
    Liquidation { lTV, lTVDivider, .. } -> {
      expect (Finite(validFrom), Finite(validTo)) =
        (
          self.validity_range.lower_bound.bound_type,
          self.validity_range.upper_bound.bound_type,
        )
      let borrowerBondOutput =
        safe_list_at(self.outputs, borrowerBondOutputIndex)
      let loanOutput =
        utils.safe_list_at(
          get_outputs_to_smart_credential(
            self.outputs,
            Script(config.loanSpendScriptHash),
            Script(config.loanPolicyId),
            config.smartTokensSpendScriptHash,
          ),
          loanInputIndex,
        )
      expect Some(ltvAsRational) = rational.new(lTV, lTVDivider)
      let collateralOracleRefInput =
        safe_list_at(self.reference_inputs, collateralOracleRefInputIndex)
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
        safe_list_at(self.reference_inputs, principalOracleRefInputIndex)
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
      and {
        quantity_of(input.output.value, loanPolicyId, loanId) == 1,
        is_nft_in_output(
          config.borrowerBondPolicyId,
          loanId,
          borrowerBondOutput,
        ),
        can_liquidate(
          rational.from_int(datum.principalAmount),
          rational.from_int(newCollateralAmount),
          ltvAsRational,
          principalOraclePriceFeed,
          collateralOraclePriceFeed,
        ) == False,
        validate_output_to_loan_for_changing_collateral(
          loanOutput,
          datum,
          newCollateralAmount,
          input.output.value,
          input.output.address.stake_credential,
          config.loanSpendScriptHash,
        ),
      }
    }
    _ -> False
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
  expect parsedDatum: LoanDatum = outputDatum

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
    parsedDatum == datum,
    //loanNFT is already included in the value
    correctValue,
  }
}
