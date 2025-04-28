use aiken/math/rational.{Rational}
use cardano/assets.{Value, quantity_of}
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

fn rational_pow(r: rational.Rational, exponent: Int) -> Rational {
  if exponent == 1 {
    r
  } else {
    rational.mul(r, rational_pow(r, exponent - 1))
  }
}

//Calculate the token_b required to purchase wanted_token_a_amount of token_a
//TODO Is this formula accepted for any AMM?
fn token_b_needed_to_purchase_token_a_in_AMM_pool(
  wanted_token_a_amount: Rational,
  token_a_amount_in_pool: Int,
  token_b_amount_in_pool: Int,
  pool_fees_per_mille: Int,
) -> Int {
  let buy_amount_int = wanted_token_a_amount |> rational.truncate()

  let nominator = buy_amount_int * 1000 * token_b_amount_in_pool
  let denominator =
    ( token_a_amount_in_pool - buy_amount_int ) * ( 1000 - pool_fees_per_mille )
  let token_b_required = nominator / denominator
  token_b_required
}

//Calculate the token_b received when selling selling_token_a_amount of token_a
//TODO Is this formula accepted for any AMM?
fn token_b_received_from_selling_token_a_in_AMM_pool(
  selling_token_a_amount: Rational,
  token_a_amount: Int,
  token_b_amount: Int,
  pool_fees_per_mille: Int,
) -> Int {
  let remaining_after_pool_fees = 1000 - pool_fees_per_mille
  let sell_amount_int = selling_token_a_amount |> rational.truncate()

  let nominator = sell_amount_int * remaining_after_pool_fees * token_b_amount
  let denominator =
    token_a_amount * 1000 + remaining_after_pool_fees * sell_amount_int
  let asset_return = nominator / denominator
  asset_return
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
    Pooled {
      token_a_amount_in_pool,
      token_b_amount_in_pool,
      pool_fees_per_mille,
      ..
    } ->
      rational.from_int(
        token_b_received_from_selling_token_a_in_AMM_pool(
          tokenAmount,
          token_a_amount_in_pool,
          token_b_amount_in_pool,
          pool_fees_per_mille,
        ),
      )
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
    Pooled {
      token_a_amount_in_pool,
      token_b_amount_in_pool,
      pool_fees_per_mille,
      ..
    } ->
      rational.from_int(
        token_b_needed_to_purchase_token_a_in_AMM_pool(
          lovelaces,
          token_a_amount_in_pool,
          token_b_amount_in_pool,
          pool_fees_per_mille,
        ),
      )
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
    PerpetualLoan {
      interestRateIncreaseLinearCoefficient,
      interestRateIncreaseLinearCoefficientDivider,
      ..
    } -> {
      let lastRepaidInstallmentTime =
        if repaidInstallments == 0 {
          0
        } else {
          initialGracePeriod + repaidInstallments * installmentPeriod
        }

      let periodToPay = timeSinceLendDate - lastRepaidInstallmentTime
      expect Some(currentInterestRateIncrease) =
        rational.new(
          interestRateIncreaseLinearCoefficient * periodToPay,
          interestRateIncreaseLinearCoefficientDivider,
        )

      let currentInterestRate =
        rational.add(currentInterestRateIncrease, interestRate)

      let currentInterest = rational.mul(principal, currentInterestRate)

      rational.ceil(rational.sub(principal, currentInterest))
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
    PerpetualLoan {
      interestRateIncreaseLinearCoefficient,
      interestRateIncreaseLinearCoefficientDivider,
      ..
    } -> {
      let periodToPay =
        if repaidInstallments == 0 {
          initialGracePeriod + installmentPeriod
        } else {
          installmentPeriod
        }

      expect Some(currentInterestRateIncrease) =
        rational.new(
          interestRateIncreaseLinearCoefficient * periodToPay,
          interestRateIncreaseLinearCoefficientDivider,
        )

      let currentInterestRate =
        rational.add(currentInterestRateIncrease, interestRate)

      let installmentAmountAsRational =
        rational.mul(principal, currentInterestRate)

      rational.ceil(
        rational.add(installmentAmountAsRational, penaltyFeeAsRational),
      )
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
) {
  let remainingDebtInLovelace =
    get_token_amount_in_lovelace(remainingDebt, principalOraclePriceFeed)
  let collateralInLovelace =
    get_token_amount_in_lovelace(collateralAmount, collateralOraclePriceFeed)

  let equityInLovelace =
    rational.sub(collateralInLovelace, remainingDebtInLovelace)

  let equity =
    get_lovelace_amount_in_token_currency(
      equityInLovelace,
      principalOraclePriceFeed,
    )

  rational.round(equity)
}

pub fn is_repayment_late(
  validFrom: Int,
  lendDate: Int,
  initialGracePeriod: Int,
  repaidInstallments: Int,
  installmentPeriod: Int,
  repaymentTimeWindow: Int,
) {
  let periodToLatestPaidInstallment =
    ( repaidInstallments + 1 ) * installmentPeriod
  validFrom > lendDate + initialGracePeriod + periodToLatestPaidInstallment + repaymentTimeWindow
}

pub fn get_due_installments(
  validFrom: Int,
  lendDate: Int,
  initialGracePeriod: Int,
  repaidInstallments: Int,
  installmentPeriod: Int,
) {
  let periodToLatestPaidInstallment =
    ( repaidInstallments + 1 ) * installmentPeriod
  let timePassed =
    validFrom - (
      lendDate + initialGracePeriod + periodToLatestPaidInstallment
    )
  timePassed / installmentPeriod
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
