use aiken/math/rational
use cardano/assets.{AssetName, Value, add, flatten, quantity_of}
use types/datum.{
  InterestOnRemainingPrincipal, PrincipalAndInterestOnInstallments,
  RepaymentMode,
}
use types/general.{Asset, CollateralAsset}
use types/redeemer.{Aggregated, Dedicated, OraclePriceFeed, Pooled}
use utils.{
  address_in_signatures, authorize_action, get_inputs_from_sc, get_outputs_to_sc,
  get_own_hash, is_output_to_sc, quantity_of_policy_id, retrieve_oracle_data,
  safe_list_at, token_b_needed_to_purchase_token_a, validate_oracle_ref_input,
  validity_range_within_an_hour,
}

//TODO Use dividers
//TODO Use rational library?
pub fn get_remaining_debt(
  repaymentMode: RepaymentMode,
  principal: Int,
  principalDivider: Int,
  interestRate: Int,
  totalInstallments: Int,
  repaidInstallments: Int,
) {
  when repaymentMode is {
    InterestOnRemainingPrincipal(..) -> todo
    PrincipalAndInterestOnInstallments -> {
      let totalInterest = principal * interestRate / 1000
      let singleInstallmentAmount =
        ( principal + totalInterest ) / totalInstallments
      ( totalInstallments - repaidInstallments ) * singleInstallmentAmount
    }
  }
}

pub fn get_repayment_amount(
  //TODO Use dividers
  //TODO Use rational library?
  repaymentMode: RepaymentMode,
  principal: Int,
  principalDivider: Int,
  interestRate: Int,
  totalInstallments: Int,
  repaidInstallments: Int,
  isLate: Bool,
  penaltyFeeForLateRepayment: Int,
) {
  when repaymentMode is {
    InterestOnRemainingPrincipal(..) -> todo
    PrincipalAndInterestOnInstallments -> {
      let totalInterest = principal * interestRate / 1000
      let singleInstallmentAmount =
        ( principal + totalInterest ) / totalInstallments
      if isLate {
        singleInstallmentAmount + penaltyFeeForLateRepayment
      } else {
        singleInstallmentAmount
      }
    }
  }
}

pub fn can_liquidate(
  collateralValueInPrincipalCurrency: Int,
  principalAmount: Int,
  principalDivider: Int,
  ltv: Int,
  lTVDivider: Int,
) {
  //TODO use dividers
  //TODO Use rational library?
  collateralValueInPrincipalCurrency / principalAmount < ltv
}

pub fn get_collateral_value_in_principal_currency(
  oraclePriceFeed: OraclePriceFeed,
  collateral: CollateralAsset,
  loanValue: Value,
) {
  let collateralAmount =
    rational.from_int(
      if collateral.maybeAssetName == None {
        quantity_of_policy_id(loanValue, collateral.policyId)
      } else {
        expect Some(assetName) = collateral.maybeAssetName
        quantity_of(loanValue, collateral.policyId, assetName)
      },
    )
  when oraclePriceFeed is {
    Aggregated(aggregated_data) -> {
      expect Some(tokenPrice) =
        rational.new(
          aggregated_data.token_price_in_lovelaces,
          aggregated_data.denominator,
        )
      rational.ceil(rational.mul(collateralAmount, tokenPrice))
    }
    Pooled(pooled_data) ->
      token_b_needed_to_purchase_token_a(
        collateralAmount,
        pooled_data.token_b_amount,
        pooled_data.token_a_amount,
      )
    Dedicated(dedicated_data) -> {
      expect Some(tokenPrice) =
        rational.new(dedicated_data.token_price, dedicated_data.denominator)

      rational.ceil(rational.mul(collateralAmount, tokenPrice))
    }
  }
}

pub fn is_repayment_late(
  validFrom: Int,
  lendDate: Int,
  initialGracePeriod: Int,
  repaidInstallments: Int,
  installmentPeriod: Int,
  repaymentTimeWindow: Int,
) {
  let periodToLatestPaidInstallment = repaidInstallments * installmentPeriod
  validFrom > lendDate + initialGracePeriod + periodToLatestPaidInstallment + repaymentTimeWindow
}

pub fn is_recasting_permitted(repaymentMode: RepaymentMode, doneRecasts: Int) {
  todo
}
