use fluidtokens/types/asset_manager.{AssetManagerDatum}
use fluidtokens/types/general.{Asset, AuthorizationMethod}

pub type DutchAuctionDatum {
  ownerAuth: AuthorizationMethod,
  //Datum to use for the result utxo that the owner can get in the AssetManager
  ownerAssetManagerDatum: AssetManagerDatum,
  currency: Asset,
  //Expressed in units
  startingPrice: Int,
  //Expressed in units
  loweringAmount: Int,
  loweringFrequency: Int,
  //Expressed in units
  minPriceToCancel: Int,
  //In POSIX millis
  startDate: Int,
  //If present it means it's a ducth auction from a liquidated asset:
  //The lender must get max principal+interest
  //The borrower gets the difference if the earning from the auction are > what lender should get
  borrowerAssetManagerDatum: Option<AssetManagerDatum>,
  //Used only if borrowerAssetManagerDatum is not None, it's how much the lender should get
  debtAmount: Int,
}

pub type DutchAuctionAction {
  Cancel
  Buy
}

pub type DutchAuctionRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<DutchAuctionAction>,
}
