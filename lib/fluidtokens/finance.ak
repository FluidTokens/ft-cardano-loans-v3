use aiken/math/rational
use cardano/assets.{Value, quantity_of}
use fluidtokens/types/datum.{
  InterestOnRemainingPrincipal, PrincipalAndInterestOnInstallments,
  RepaymentMode,
}
use fluidtokens/types/general.{CollateralAsset}
use fluidtokens/types/redeemer.{Aggregated, Dedicated, OraclePriceFeed, Pooled}
use fluidtokens/utils.{quantity_of_policy_id, token_b_needed_to_purchase_token_a}

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
  expect Some(penaltyFeeAsRational) =
    rational.new(
      if isLate {
        penaltyFeeForLateRepayment
      } else {
        0
      },
      principalDivider,
    )
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
            totalInstallments,
          ),
          oneAsRational,
        )
      expect Some(result) = rational.div(numerator, denominator)

      rational.ceil(rational.add(result, penaltyFeeAsRational))
    }
    PrincipalAndInterestOnInstallments -> {
      let totalInterest = rational.mul(principalAsRational, interestAsRational)
      expect Some(singleInstallmentAmountAsRational) =
        rational.div(
          rational.add(principalAsRational, totalInterest),
          rational.from_int(totalInstallments),
        )
      rational.ceil(
        rational.add(singleInstallmentAmountAsRational, penaltyFeeAsRational),
      )
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
    Aggregated { token_price_in_lovelaces, denominator, .. } -> {
      expect Some(tokenPrice) =
        rational.new(token_price_in_lovelaces, denominator)
      rational.ceil(rational.mul(collateralAmount, tokenPrice))
    }
    Pooled { token_b_amount, token_a_amount, .. } ->
      token_b_needed_to_purchase_token_a(
        collateralAmount,
        token_b_amount,
        token_a_amount,
      )
    Dedicated { token_price, denominator, .. } -> {
      expect Some(tokenPrice) = rational.new(token_price, denominator)

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
