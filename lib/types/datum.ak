use cardano/address.{Address}
use cardano/assets.{AssetName}
use types/general.{Asset, CollateralAsset}

//TODO Deferment
//TODO LOAN REFINANCING IS MISSING
//TODO Penalty for late payments, to eventual external address
//Forgiveness in case of default is accomplished by sending the collateral back to the borrower
pub type RepaymentMode {
  //Express number of possible recasts. 0 means no recasting, negative means unlimited
  InterestOnRemainingPrincipal { max_possible_recasts: Int }
  PrincipalAndInterestOnInstallments
}

pub type LiquidationMode {
  NoLiquidationClaimFullCollateral
  NoLiquidationDutchAuctionClaim
  Liquidation {
    //Time between last installment paid and liquidation.
    //Used only when liquidation is enabled
    deltaTimeForLiquidation: Int,
    //This has (either pubKeyHash or scriptHash) is authorized to liquidate when possible.
    //If it's "" then anyone can liquidate.
    //Used only when liquidation is enabled
    liquidatorAuthHash: ByteArray,
  }
}

pub type CommonData {
  poolAsset: Asset,
  //LTV for each collateral option (borrower can ask more using a multiple). No oracle then this is the principal amount
  principalLTV: List<Int>,
  principalLTVDivider: List<Int>,
  //Per mille of the loan to repay to lender
  interestRate: Int,
  duration: Int,
  //period after starting the loan and before starting repaying
  initialGracePeriod: Int,
  totalInstallments: Int,
  liquidationMode: LiquidationMode,
}

pub type RequestDatum {
  commonData: CommonData,
  borrowerAuthHash: ByteArray,
  borrowerAddress: Address,
  //This pool can cover multiple collections/token, but only one of them can be chosen for each loan (ie. no mixed bundle loans).
  //Important requirement: if liquidation is enabled, ALL the collateralOptions must have an oracle NFT
  collateralOptions: List<CollateralAsset>,
  //True if borrowable amount of the collateralOptions must be updated through oracles
  dynamicCollateralPrice: Bool,
}

pub type PoolDatum {
  commonData: CommonData,
  lenderAuthHash: ByteArray,
  lenderAddress: Address,
  //This pool can cover multiple collections/token, but only one of them can be chosen for each loan (ie. no mixed bundle loans).
  //Important requirement: if liquidation is enabled, ALL the collateralOptions must have an oracle NFT
  collateralOptions: List<CollateralAsset>,
  //True if borrowable amount of the collateralOptions must be updated through oracles
  dynamicCollateralPrice: Bool,
}

pub type ActiveDatum {
  commonData: CommonData,
  borrowerAssetName: AssetName,
  lenderAssetName: AssetName,
  collateral: CollateralAsset,
  lendDate: Int,
  installmentsRepaid: Int,
}

pub type DutchAuctionDatum {
  DutchAuctionDatum
}
