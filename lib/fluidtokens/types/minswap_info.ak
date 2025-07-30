use aiken/collection/dict.{Dict}
use cardano/address.{Credential}
use fluidtokens/types/general.{Asset}

pub type MinswapV2Info {
  //Key is the concatenated units of the pool assets ordered lexigrophically (B and A -> "AB").
  //In the value pair, the first field is the LP token, 
  //the second is true if the pool direction is AB, false if it's BA.
  lpAssetForPoolAssetPairAndDirection: Data<Dict<ByteArray, (Asset, Bool)>>,
  adminCredential: Credential,
}
