use cardano/address.{Address}
use cardano/assets.{AssetName}
use types/general.{Asset, CollateralAsset}

pub type CommonLoanData {
  poolAsset: Asset,
  //LTV for each collateral option (borrower can ask more using a multiple). No oracle then this is the principal amount
  principalLTV: List<Int>,
  principalLTVDivider: List<Int>,
  //Per mille of the loan to repay to lender
  interestRate: Int,
  loanDuration: Int,
  totalInstallments: Int,
  liquidationEnabled: Bool,
  //Time between last installment paid and liquidation
  deltaTimeForLiquidation: Int,
}

pub type OracleLTVPoolDatum {
  commonLoanData: CommonLoanData,
  lenderAuthHash: ByteArray,
  lenderAddress: Address,
  //This pool can cover multiple collections/token, but only one of them can be chosen for each loan (ie. no mixed bundle loans).
  //Important requirement: if liquidation is enabled, ALL the collateralOptions must have an oracle NFT
  collateralOptions: List<CollateralAsset>,
}

pub type ActiveLoanDatum {
  commonLoanData: CommonLoanData,
  borrowerAssetName: AssetName,
  lenderAssetName: AssetName,
  collateral: CollateralAsset,
  lendDate: Int,
  installmentsRepaid: Int,
}
