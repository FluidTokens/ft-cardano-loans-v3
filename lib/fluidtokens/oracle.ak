use aiken/collection/pairs
use cardano/address.{PaymentCredential}
use cardano/assets.{Value, quantity_of}
use cardano/transaction.{Redeemer, ScriptPurpose, Withdraw}
use fluidtokens/constants
use fluidtokens/types/general.{Asset}
use fluidtokens/types/oracle.{
  Aggregated, CommonFeedData, Dedicated, OraclePriceFeed, OracleRedeemer, Pooled,
  PriceDataCharlie, PriceDataOrcfax,
}

//Ensure that the oracle is showing the data of the token
fn is_feed_token_correct(
  expectedTokenPolicyId: ByteArray,
  expectedTokenMaybeAssetName: Option<ByteArray>,
  feedToken: Asset,
) {
  when expectedTokenMaybeAssetName is {
    Some(assetName) -> and {
        feedToken.policyId == expectedTokenPolicyId,
        feedToken.assetName == assetName,
      }
    None -> feedToken.policyId == expectedTokenPolicyId
  }
}

//Find the oracle redeemer containing the token data
pub fn retrieve_oracle_data(
  oraclePaymentCredential: PaymentCredential,
  oracleInputValue: Value,
  redeemers: Pairs<ScriptPurpose, Redeemer>,
  transactionValidFrom: Int,
  transactionValidTo: Int,
  oracleTokenPolicyId: ByteArray,
  oracleTokenAssetName: ByteArray,
  expectedTokenPolicyId: ByteArray,
  expectedTokenMaybeAssetName: Option<ByteArray>,
) -> Option<OraclePriceFeed> {
  if expectedTokenPolicyId == "" {
    Some(
      Aggregated {
        common: CommonFeedData {
          valid_from: 0,
          valid_to: 0,
          token: Asset { policyId: "", assetName: "" },
        },
        token_price_in_lovelaces: 1,
        token_price_denominator: 1,
      },
    )
  } else {
    expect Some(oracleRedeemer) =
      pairs.get_first(redeemers, Withdraw(oraclePaymentCredential))
    expect parsedOracleRedeemer: OracleRedeemer = oracleRedeemer

    let commonFeedData =
      when parsedOracleRedeemer.data is {
        Pooled { common, .. } -> common
        Aggregated { common, .. } -> common
        Dedicated { common, .. } -> common
        PriceDataCharlie { common, .. } -> common
        PriceDataOrcfax { common, .. } -> common
      }

    if and {
      commonFeedData.valid_to - commonFeedData.valid_from <= constants.max_oracle_validity_range,
      commonFeedData.valid_to >= transactionValidTo,
      commonFeedData.valid_from <= transactionValidFrom,
      is_feed_token_correct(
        expectedTokenPolicyId,
        expectedTokenMaybeAssetName,
        commonFeedData.token,
      ),
      //Oracle ref input contains expected oracle nft
      quantity_of(oracleInputValue, oracleTokenPolicyId, oracleTokenAssetName) > 0,
    } {
      Some(parsedOracleRedeemer.data)
    } else {
      trace @"oracle is expired, has wrong token or wrong interval or oracle doesn't contain oracle nft"
      None
    }
  }
}
