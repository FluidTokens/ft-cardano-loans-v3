use amm_dex_v2/types as minswap_types
use fluidtokens/types/general.{Asset, AuthorizationMethod}

// Conversion functions between our AuthorizationMethod type and minswap's OrderAuthorizationMethod type:

// Convert from AuthorizationMethod to OrderAuthorizationMethod (Minswap)
pub fn to_order_auth_method(
  auth_method: AuthorizationMethod,
) -> minswap_types.OrderAuthorizationMethod {
  when auth_method is {
    general.CardanoSignature { hash } ->
      minswap_types.OAMSignature { pub_key_hash: hash }
    general.CardanoSpendScript { hash } ->
      minswap_types.OAMSpendScript { script_hash: hash }
    general.CardanoWithdrawScript { hash } ->
      minswap_types.OAMWithdrawScript { script_hash: hash }
    general.CardanoMintScript { hash } ->
      minswap_types.OAMMintScript { script_hash: hash }
  }
}

// Convert from OrderAuthorizationMethod (Minswap) to AuthorizationMethod
pub fn from_order_auth_method(
  order_auth_method: minswap_types.OrderAuthorizationMethod,
) -> AuthorizationMethod {
  when order_auth_method is {
    minswap_types.OAMSignature { pub_key_hash } ->
      general.CardanoSignature { hash: pub_key_hash }
    minswap_types.OAMSpendScript { script_hash } ->
      general.CardanoSpendScript { hash: script_hash }
    minswap_types.OAMWithdrawScript { script_hash } ->
      general.CardanoWithdrawScript { hash: script_hash }
    minswap_types.OAMMintScript { script_hash } ->
      general.CardanoMintScript { hash: script_hash }
  }
}

// Conversion functions between our Asset type and minswap's Asset type:

// Convert from minswap_types.Asset to our Asset type
pub fn from_minswap_asset(minswapAsset: minswap_types.Asset) -> Asset {
  Asset { policyId: minswapAsset.policy_id, assetName: minswapAsset.asset_name }
}

// Convert from our Asset type to minswap_types.Asset
pub fn to_minswap_asset(asset: Asset) -> minswap_types.Asset {
  minswap_types.Asset { policy_id: asset.policyId, asset_name: asset.assetName }
}
