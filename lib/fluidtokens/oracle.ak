use aiken/collection/pairs
use cardano/address.{PaymentCredential}
use cardano/assets.{Value, quantity_of}
use cardano/transaction.{Redeemer, ScriptPurpose, Withdraw}
use fluidtokens/constants
use fluidtokens/types/general.{Asset, CollateralAsset}
use fluidtokens/types/redeemer.{
  Aggregated, Dedicated, OraclePriceFeed, OracleRedeemer, Pooled,
}

//Ensure that the input value has the oracle token defined by the collateral
pub fn validate_oracle_ref_input_value(
  oracleInputValue: Value,
  collateral: CollateralAsset,
) {
  expect Some(oracleToken) = collateral.maybeOracleTokenAsset
  quantity_of(oracleInputValue, oracleToken.policyId, oracleToken.assetName) > 0
}

//Ensure that the oracle is showing the data of the collateral token
fn is_feed_token_correct(expectedCollateral: CollateralAsset, feedToken: Asset) {
  when expectedCollateral.maybeAssetName is {
    Some(assetName) -> and {
        feedToken.policyId == expectedCollateral.policyId,
        feedToken.assetName == assetName,
      }
    None -> feedToken.policyId == expectedCollateral.policyId
  }
}

//Find the oracle redeemer containing the collateral token data
pub fn retrieve_oracle_data(
  oraclePaymentCredential: PaymentCredential,
  redeemers: Pairs<ScriptPurpose, Redeemer>,
  transactionValidTo: Int,
  expectedCollateral: CollateralAsset,
) -> Option<OraclePriceFeed> {
  expect Some(oracleRedeemer) =
    pairs.get_first(redeemers, Withdraw(oraclePaymentCredential))
  expect parsedOracleRedeemer: OracleRedeemer = oracleRedeemer

  let commonFeedData =
    when parsedOracleRedeemer.data is {
      Pooled { common, .. } -> common
      Aggregated { common, .. } -> common
      Dedicated { common, .. } -> common
    }
  if and {
    commonFeedData.valid_to - commonFeedData.valid_from <= constants.max_oracle_validity_range,
    commonFeedData.valid_to >= transactionValidTo,
    is_feed_token_correct(expectedCollateral, commonFeedData.token),
  } {
    Some(parsedOracleRedeemer.data)
  } else {
    trace @"oracle is expired, has wrong token or wrong interval"
    None
  }
}
