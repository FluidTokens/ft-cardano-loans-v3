use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use cardano/address.{Address, Credential, Script, StakeCredential}
use cardano/assets.{AssetName, Value, add, flatten, quantity_of}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use finance.{
  can_liquidate, get_collateral_value_in_principal_currency, get_remaining_debt,
  get_repayment_amount, is_recasting_permitted, is_repayment_late,
}
use types/datum.{
  ActiveDatum, DutchAuctionDatum, Liquidation, NoLiquidationDutchAuctionClaim,
  NoLiquidationFullCollateralClaim, RepaymentDatum, RepaymentDatumWithBond,
}
use types/general.{Asset, CollateralAsset}
use types/redeemer.{
  AddCollateral, Claim, DA_Buy, DA_Cancel, DutchAuctionRedeemer, Recast, Repay,
}
use utils.{
  get_inputs_from_sc_or_delegated_to_sc, get_outputs_to_sc_or_delegated_to_sc,
  is_nft_spent, is_output_to_sc, quantity_of_policy_id, retrieve_oracle_data,
  safe_list_at, validate_oracle_ref_input, value_without_policy_id_as_list,
}

validator activeLoan {
  withdraw(
    redeemer: DutchAuctionRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(ownScriptHash) = credential
    let scInputs =
      get_inputs_from_sc_or_delegated_to_sc(self.inputs, ownScriptHash)
    //Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
    expect length(scInputs) == length(redeemer.actionForEachInput)
    expect Finite(validFrom) = self.validity_range.lower_bound.bound_type
    expect Finite(validTo) = self.validity_range.upper_bound.bound_type

    list.indexed_foldr(
      scInputs,
      True,
      fn(index, inputAndCIP113Control, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        let input = inputAndCIP113Control.1st
        let isCIP113 = inputAndCIP113Control.2nd
        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: ActiveDatum = inputDatum
        let redeemerAction = safe_list_at(redeemer.actionForEachInput, index)

        when redeemerAction is {
          DA_Buy -> todo
          DA_Cancel -> todo
        }
      },
    )
  }

  else(_) {
    fail
  }
}
