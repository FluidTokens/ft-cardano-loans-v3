use aiken/math/rational
use cardano/assets.{Value, quantity_of}
use types/datum.{
  InterestOnRemainingPrincipal, PrincipalAndInterestOnInstallments,
  RepaymentMode,
}
use types/general.{CollateralAsset}
use types/redeemer.{Aggregated, Dedicated, OraclePriceFeed, Pooled}
use utils.{quantity_of_policy_id, token_b_needed_to_purchase_token_a}

fn rational_pow(r: rational.Rational, exponent: Int) {
  if exponent == 1 {
    r
  } else {
    rational.mul(r, rational_pow(r, exponent - 1))
  }
}

pub fn get_remaining_debt(
  repaymentMode: RepaymentMode,
  principal: Int,
  principalDivider: Int,
  interestRate: Int,
  totalInstallments: Int,
  repaidInstallments: Int,
) {
  ( totalInstallments - repaidInstallments ) * get_repayment_amount(
    repaymentMode,
    principal,
    principalDivider,
    interestRate,
    totalInstallments,
    False,
    0,
  )
}

pub fn get_repayment_amount(
  repaymentMode: RepaymentMode,
  principal: Int,
  principalDivider: Int,
  interestRate: Int,
  totalInstallments: Int,
  isLate: Bool,
  penaltyFeeForLateRepayment: Int,
) {
  expect Some(principalAsRational) = rational.new(principal, principalDivider)
  expect Some(interestAsRational) =
    rational.div(rational.from_int(interestRate), rational.from_int(1000))
  expect Some(penaltyFeeForLateRepaymentAsRational) =
    rational.new(penaltyFeeForLateRepayment, principalDivider)
  when repaymentMode is {
    InterestOnRemainingPrincipal(..) -> {
      let oneAsRational = rational.from_int(1)
      //Amortization formula
      expect Some(interestPerInstallmentAsRational) =
        rational.div(interestAsRational, rational.from_int(totalInstallments))
      let numerator =
        rational_pow(
          rational.mul(
            rational.mul(principalAsRational, interestPerInstallmentAsRational),
            rational.add(oneAsRational, interestPerInstallmentAsRational),
          ),
          totalInstallments,
        )
      let denominator =
        rational.sub(
          rational_pow(
            rational.add(oneAsRational, interestPerInstallmentAsRational),
            totalInstallments
          ),
          oneAsRational
        )
      expect Some(result) = rational.div(numerator, denominator)
      if isLate {
        rational.ceil(
          rational.add(result, penaltyFeeForLateRepaymentAsRational),
        )
      } else {
        rational.ceil(result)
      }
    }
    PrincipalAndInterestOnInstallments -> {
      let totalInterest = rational.mul(principalAsRational, interestAsRational)
      expect Some(singleInstallmentAmountAsRational) =
        rational.div(
          rational.add(principalAsRational, totalInterest),
          rational.from_int(totalInstallments),
        )
      if isLate {
        rational.ceil(
          rational.add(
            singleInstallmentAmountAsRational,
            penaltyFeeForLateRepaymentAsRational,
          ),
        )
      } else {
        rational.ceil(singleInstallmentAmountAsRational)
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
  expect Some(principalAsRational) =
    rational.new(principalAmount, principalDivider)
  expect Some(collateralValueInPrincipalCurrencyAsRational) =
    rational.new(collateralValueInPrincipalCurrency, principalDivider)
  expect Some(ratioAsRational) =
    rational.div(
      collateralValueInPrincipalCurrencyAsRational,
      principalAsRational,
    )

  expect Some(ltvAsRational) = rational.new(ltv, lTVDivider)
  rational.compare(ltvAsRational, ratioAsRational) == Greater
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
  expect InterestOnRemainingPrincipal(max_possible_recasts) = repaymentMode
  doneRecasts < max_possible_recasts
}
