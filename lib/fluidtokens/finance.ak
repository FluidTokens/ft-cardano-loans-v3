use aiken/math/rational.{Rational}
use cardano/assets.{Value, quantity_of}
use fluidtokens/constants
use fluidtokens/types/general.{CollateralAsset}
use fluidtokens/types/oracle.{
  Aggregated, Dedicated, OraclePriceFeed, Pooled, PriceDataCharlie,
  PriceDataOrcfax,
}
use fluidtokens/types/pool.{
  InterestOnRemainingPrincipal, PerpetualLoan,
  PrincipalAndInterestOnInstallments, RepaymentMode,
}
use fluidtokens/utils.{quantity_of_policy_id}

fn rational_safe_div(r1: rational.Rational, r2: rational.Rational) -> Rational {
  expect Some(result) = rational.div(r1, r2)
  result
}

fn rational_pow(r: rational.Rational, exponent: Int) -> Rational {
  if exponent == 1 {
    r
  } else {
    rational.mul(r, rational_pow(r, exponent - 1))
  }
}

fn get_token_amount_in_lovelace(
  tokenAmount: Rational,
  oraclePriceFeed: OraclePriceFeed,
) -> Rational {
  when oraclePriceFeed is {
    Aggregated { token_price_in_lovelaces, token_price_denominator, .. } -> {
      expect Some(tokenPrice) =
        rational.new(token_price_in_lovelaces, token_price_denominator)
      rational.mul(tokenPrice, tokenAmount)
    }
    Pooled { .. } -> fail
    Dedicated { price_in_lovelaces, price_denominator, .. } -> {
      expect Some(tokenPrice) =
        rational.new(price_in_lovelaces, price_denominator)
      rational.mul(tokenPrice, tokenAmount)
    }
    PriceDataCharlie { price_in_lovelaces, price_denominator, .. } -> {
      expect Some(tokenPrice) =
        rational.new(price_in_lovelaces, price_denominator)
      rational.mul(tokenPrice, tokenAmount)
    }
    PriceDataOrcfax { price_in_lovelaces, price_denominator, .. } -> {
      expect Some(tokenPrice) =
        rational.new(price_in_lovelaces, price_denominator)
      rational.mul(tokenPrice, tokenAmount)
    }
  }
}

fn get_lovelace_amount_in_token_currency(
  lovelaces: Rational,
  tokenOraclePriceFeed: OraclePriceFeed,
) -> Rational {
  when tokenOraclePriceFeed is {
    Aggregated { token_price_in_lovelaces, token_price_denominator, .. } -> {
      expect Some(tokenPrice) =
        rational.new(token_price_in_lovelaces, token_price_denominator)
      expect Some(tokensAmount) = rational.div(lovelaces, tokenPrice)
      tokensAmount
    }
    Pooled { .. } -> fail
    Dedicated { price_in_lovelaces, price_denominator, .. } -> {
      expect Some(tokenPrice) =
        rational.new(price_in_lovelaces, price_denominator)
      expect Some(tokensAmount) = rational.div(lovelaces, tokenPrice)
      tokensAmount
    }
    PriceDataCharlie { price_in_lovelaces, price_denominator, .. } -> {
      expect Some(tokenPrice) =
        rational.new(price_in_lovelaces, price_denominator)
      expect Some(tokensAmount) = rational.div(lovelaces, tokenPrice)
      tokensAmount
    }
    PriceDataOrcfax { price_in_lovelaces, price_denominator, .. } -> {
      expect Some(tokenPrice) =
        rational.new(price_in_lovelaces, price_denominator)
      expect Some(tokensAmount) = rational.div(lovelaces, tokenPrice)
      tokensAmount
    }
  }
}

pub fn get_collateral_amount(
  value: Value,
  collateral: CollateralAsset,
) -> Rational {
  rational.from_int(
    if collateral.maybeAssetName == None {
      quantity_of_policy_id(value, collateral.policyId)
    } else {
      expect Some(assetName) = collateral.maybeAssetName
      quantity_of(value, collateral.policyId, assetName)
    },
  )
}

//Formula is: principal * collateralNeededPerPrincipalUnit
//Result is expressed in collateral currency
pub fn get_needed_collateral_without_oracles(
  wantedPrincipalAmount: Int,
  collateralPerSinglePrincipalUnit: Rational,
) {
  let wantedPrincipalAmountAsRational = rational.from_int(wantedPrincipalAmount)
  rational.ceil(
    rational.mul(
      wantedPrincipalAmountAsRational,
      collateralPerSinglePrincipalUnit,
    ),
  )
}

//Formula is: collateral = principal / LTV
//Result is expressed in collateral currency
pub fn get_needed_collateral_with_oracles(
  wantedPrincipalAmount: Int,
  ltv: Rational,
  principalOraclePriceFeed: OraclePriceFeed,
  collateralOraclePriceFeed: OraclePriceFeed,
) -> Int {
  let wantedPrincipalInLovelace =
    get_token_amount_in_lovelace(
      rational.from_int(wantedPrincipalAmount),
      principalOraclePriceFeed,
    )

  expect Some(collateralInLovelace) =
    rational.div(wantedPrincipalInLovelace, ltv)

  rational.ceil(
    get_lovelace_amount_in_token_currency(
      collateralInLovelace,
      collateralOraclePriceFeed,
    ),
  )
}

pub fn get_min_principal_for_collateral_without_oracles(
  collateralAmount: Rational,
  collateralPerSinglePrincipalUnit: Rational,
) {
  expect Some(minPrincipal) =
    rational.div(collateralAmount, collateralPerSinglePrincipalUnit)
  rational.ceil(minPrincipal)
}

pub fn get_min_principal_for_collateral_with_oracles(
  collateralAmount: Rational,
  ltv: Rational,
  principalOraclePriceFeed: OraclePriceFeed,
  collateralOraclePriceFeed: OraclePriceFeed,
) {
  let collateralAmountInLovelace =
    get_token_amount_in_lovelace(collateralAmount, collateralOraclePriceFeed)

  let principalInLovelace = rational.mul(collateralAmountInLovelace, ltv)

  rational.ceil(
    get_lovelace_amount_in_token_currency(
      principalInLovelace,
      principalOraclePriceFeed,
    ),
  )
}

//Liquidate when current LTV is smaller or equal to the decided one
//Principal and collateral are expressed in their respective units
pub fn can_liquidate(
  principal: Rational,
  collateral: Rational,
  liquidationLtv: Rational,
  principalOraclePriceFeed: OraclePriceFeed,
  collateralOraclePriceFeed: OraclePriceFeed,
) {
  let principalInLovelace =
    get_token_amount_in_lovelace(principal, principalOraclePriceFeed)
  let collateralInLovelace =
    get_token_amount_in_lovelace(collateral, collateralOraclePriceFeed)

  or {
    collateralInLovelace == rational.zero,
    {
      expect Some(currentLtv) =
        rational.div(principalInLovelace, collateralInLovelace)

      rational.compare(liquidationLtv, currentLtv) == Less
    },
  }
}

//Remaining debt expressed in principal currency
//It ignores any late repayment penalty.
pub fn get_remaining_debt(
  repaymentMode: RepaymentMode,
  principal: Rational,
  interestRate: Rational,
  totalInstallments: Int,
  repaidInstallments: Int,
  installmentPeriod: Int,
  initialGracePeriod: Int,
  timeSinceLendDate: Int,
) {
  when repaymentMode is {
    PerpetualLoan { apyIncreaseLinearCoefficient, .. } -> {
      //The formula is:
      //remainingDebt = principal*hourlyInterestRate*passedHoursSinceLastRepaidInstallment + principal*m*passedHoursSoFar/8760*passedHoursSoFar
      //which becomes:
      //remainingDebt = principal*((hourlyInterestRate*passedHoursSinceLastRepaidInstallment) + (m*passedHoursSoFar^2/8760))
      expect Some(passedHoursSoFar) = rational.new(timeSinceLendDate, 3600000)
      expect Some(m) = rational.new(apyIncreaseLinearCoefficient, 1000000)

      let accumulatedHoursOfRepaidInstallments =
        rational.from_int(
          initialGracePeriod + installmentPeriod * repaidInstallments,
        )

      let passedHoursSinceLastRepaidInstallment =
        rational.sub(passedHoursSoFar, accumulatedHoursOfRepaidInstallments)

      let firstPiece =
        rational.mul(m, rational.mul(principal, passedHoursSoFar))

      let secondPiece =
        rational.mul(
          rational.mul(
            rational_safe_div(interestRate, rational.from_int(8760)),
            passedHoursSinceLastRepaidInstallment,
          ),
          principal,
        )

      // trace accumulatedHoursOfRepaidInstallments
      // trace passedHoursSinceLastRepaidInstallment
      // trace firstPiece
      // trace secondPiece
      rational.ceil(
        rational.add(principal, rational.add(firstPiece, secondPiece)),
      )
    }

    _ ->
      ( totalInstallments - repaidInstallments ) * get_next_installment_amount(
        repaymentMode,
        principal,
        interestRate,
        totalInstallments,
        repaidInstallments,
        installmentPeriod,
        initialGracePeriod,
        False,
        0,
      )
  }
}

//Installment expressed in principal currency
//TODO Should we do the subtraction if it's the last installment?
pub fn get_next_installment_amount(
  repaymentMode: RepaymentMode,
  principal: Rational,
  interestRate: Rational,
  totalInstallments: Int,
  repaidInstallments: Int,
  installmentPeriod: Int,
  initialGracePeriod: Int,
  isLate: Bool,
  penaltyFeeForLateRepayment: Int,
) {
  let penaltyFeeAsRational =
    rational.from_int(
      if isLate {
        penaltyFeeForLateRepayment
      } else {
        0
      },
    )
  when repaymentMode is {
    InterestOnRemainingPrincipal(..) -> {
      let oneAsRational = rational.from_int(1)
      //Amortization formula
      expect Some(interestPerInstallmentAsRational) =
        rational.div(interestRate, rational.from_int(totalInstallments))
      let numerator =
        rational.mul(
          rational.mul(principal, interestPerInstallmentAsRational),
          rational_pow(
            rational.add(oneAsRational, interestPerInstallmentAsRational),
            totalInstallments,
          ),
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
      let totalInterest = rational.mul(principal, interestRate)
      expect Some(singleInstallmentAmountAsRational) =
        rational.div(
          rational.add(principal, totalInterest),
          rational.from_int(totalInstallments),
        )
      rational.ceil(
        rational.add(singleInstallmentAmountAsRational, penaltyFeeAsRational),
      )
    }
    PerpetualLoan { .. } -> {
      //Borrower repays only the interest, which corresponds to principal*hourlyInterestRate*periodToPayInHours
      let periodToPayInHours =
        if repaidInstallments == 0 {
          initialGracePeriod + installmentPeriod
        } else {
          installmentPeriod
        }

      expect Some(hourlyInterestRate) =
        rational.div(interestRate, rational.from_int(8760))

      let interestRateInPeriod =
        rational.mul(rational.from_int(periodToPayInHours), hourlyInterestRate)

      //Only pay interest
      let installmentAmount = rational.mul(principal, interestRateInPeriod)

      rational.ceil(rational.add(installmentAmount, penaltyFeeAsRational))
    }
  }
}

//Equity is the value of collateral that should go back to borrower during liquidation, 
//expressed in principal currency
pub fn get_equity(
  collateralAmount: Rational,
  remainingDebt: Rational,
  principalOraclePriceFeed: OraclePriceFeed,
  collateralOraclePriceFeed: OraclePriceFeed,
  partialLiquidationPenaltyPerMille: Int,
) {
  let remainingDebtInLovelace =
    get_token_amount_in_lovelace(remainingDebt, principalOraclePriceFeed)
  let collateralInLovelace =
    get_token_amount_in_lovelace(collateralAmount, collateralOraclePriceFeed)

  expect Some(partialLiquidationPenaltyAsRational) =
    rational.new(partialLiquidationPenaltyPerMille, 1000)

  let partialLiquidationPenalty =
    rational.mul(remainingDebtInLovelace, partialLiquidationPenaltyAsRational)

  let equityInLovelace =
    rational.sub(
      rational.sub(collateralInLovelace, remainingDebtInLovelace),
      partialLiquidationPenalty,
    )

  let equity =
    get_lovelace_amount_in_token_currency(
      equityInLovelace,
      principalOraclePriceFeed,
    )

  rational.floor(equity)
}

pub fn is_repayment_late(
  isPerpetualLoan: Bool,
  currentTime: Int,
  lendDate: Int,
  initialGracePeriod: Int,
  repaidInstallments: Int,
  installmentPeriod: Int,
  repaymentTimeWindow: Int,
) {
  let periodToLatestPaidInstallment =
    ( repaidInstallments + 1 ) * installmentPeriod
  and {
    !(isPerpetualLoan && installmentPeriod == 0),
    currentTime > lendDate + (
      initialGracePeriod + periodToLatestPaidInstallment + repaymentTimeWindow
    ) * constants.hour_to_millis,
  }
}

pub fn get_due_installments(
  validTo: Int,
  lendDate: Int,
  initialGracePeriod: Int,
  repaidInstallments: Int,
  installmentPeriod: Int,
) {
  let periodToLatestPaidInstallment = repaidInstallments * installmentPeriod
  let timePassed =
    validTo - (
      lendDate + ( initialGracePeriod + periodToLatestPaidInstallment ) * constants.hour_to_millis
    )
  timePassed / ( installmentPeriod * constants.hour_to_millis )
}

pub fn is_recasting_permitted(
  repaymentMode: RepaymentMode,
  doneRecasts: Int,
  repaidInstallments: Int,
  dueInstallments: Int,
) {
  //A Recast is permitted only when all due installments + 1 are paid, otherwise the borrower avoids paying what is due
  expect repaidInstallments >= dueInstallments + 1
  when repaymentMode is {
    InterestOnRemainingPrincipal { max_possible_recasts } ->
      doneRecasts < max_possible_recasts
    PerpetualLoan { max_possible_recasts, .. } ->
      doneRecasts < max_possible_recasts
    _ -> fail
  }
}

//c = 1000/10000, m = 100/1000000
test perpetual_installment_amount() {
  let repaymentMode =
    PerpetualLoan { apyIncreaseLinearCoefficient: 100, max_possible_recasts: 0 }
  expect Some(principal) = rational.new(1000000000, 1)
  expect Some(interestRate) = rational.new(1000, 10000)

  let installmentAmount =
    get_next_installment_amount(
      repaymentMode: repaymentMode,
      principal: principal,
      interestRate: interestRate,
      totalInstallments: 8,
      repaidInstallments: 0,
      installmentPeriod: 730,
      initialGracePeriod: 0,
      isLate: False,
      penaltyFeeForLateRepayment: 0,
    )
  installmentAmount == 8210000
}

//c = 1000/10000, m = 100/1000000
test perpetual_remaining_debt() {
  let repaymentMode =
    PerpetualLoan { apyIncreaseLinearCoefficient: 100, max_possible_recasts: 0 }
  expect Some(principal) = rational.new(1000000000, 1)
  expect Some(interestRate) = rational.new(1000, 10000)

  let debt =
    get_remaining_debt(
      repaymentMode: repaymentMode,
      principal: principal,
      interestRate: interestRate,
      totalInstallments: 200,
      repaidInstallments: 3,
      installmentPeriod: 730,
      initialGracePeriod: 0,
      timeSinceLendDate: 31536000000,
    )

  debt == 2000000000
}
