use aiken/collection/pairs
use cardano/address.{Address}
use cardano/assets.{Value, quantity_of}
use cardano/transaction.{Input, Output, Redeemer, ScriptPurpose, Withdraw}
use fluidtokens/types/general.{Asset, CollateralAsset}
use fluidtokens/types/redeemer.{
  Aggregated, Dedicated, OraclePriceFeed, OracleRedeemer, Pooled,
}

pub fn validate_oracle_ref_input(
  oracleInputValue: Value,
  chosenCollateral: CollateralAsset,
) {
  expect Some(oracleToken) = chosenCollateral.maybeOracleTokenAsset
  quantity_of(oracleInputValue, oracleToken.policyId, oracleToken.assetName) > 0
}

pub fn is_feed_token_correct(
  expectedCollateral: CollateralAsset,
  feedToken: Asset,
) {
  when expectedCollateral.maybeAssetName is {
    Some(assetName) -> and {
        feedToken.policyId == expectedCollateral.policyId,
        feedToken.assetName == assetName,
      }
    None -> feedToken.policyId == expectedCollateral.policyId
  }
}

pub fn retrieve_oracle_data(
  oracleInput: Input,
  redeemers: Pairs<ScriptPurpose, Redeemer>,
  transaction_valid_to: Int,
  expectedCollateral: CollateralAsset,
) -> Option<OraclePriceFeed> {
  expect Some(loan_oracle_redeemer) =
    pairs.get_first(
      redeemers,
      Withdraw(oracleInput.output.address.payment_credential),
    )
  expect loan_tokens_price: OracleRedeemer = loan_oracle_redeemer

  let commonFeedData =
    when loan_tokens_price.data is {
      Pooled { common, .. } -> common
      Aggregated { common, .. } -> common
      Dedicated { common, .. } -> common
    }
  if and {
    commonFeedData.valid_to - commonFeedData.valid_from <= 3600000,
    commonFeedData.valid_to >= transaction_valid_to,
    is_feed_token_correct(expectedCollateral, commonFeedData.token),
  } {
    Some(loan_tokens_price.data)
  } else {
    trace @"oracle is expired, has wrong token or wrong interval"
    None
  }
}
