use types/datum.{
  InterestOnRemainingPrincipal, PrincipalAndInterestOnInstallments,
  RepaymentMode,
}
use types/redeemer.{OraclePriceFeed}

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
  collateralAdaValue: Int,
  principalAmount: Int,
  principalDivider: Int,
  ltv: Int,
  lTVDivider: Int,
) {
  //TODO use dividers
  //TODO funziona per principal non ada?
  //TODO Use rational library?
  collateralAdaValue / principalAmount < ltv
}

pub fn get_collateral_ada_value(oraclePriceFeed: OraclePriceFeed) {
  todo
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
