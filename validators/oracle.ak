use aiken/builtin
use aiken/collection/list
use aiken/math
use cardano/address.{Credential}
use cardano/assets.{quantity_of}
use cardano/transaction.{InlineDatum, OutputReference, Transaction}
use fluidtokens/authorizer
use fluidtokens/constants
use fluidtokens/types/oracle.{
  CharlieTokenSpecs, OracleDatum, OracleRedeemer, PriceDataCharlie,
} as o
use fluidtokens/utils.{
  get_expiry, get_oracle_config, get_oracle_price, get_oracle_timestamp,
}

validator oracle(
  verification_keys: List<ByteArray>,
  threshold: Int,
  _oracle_asset_policy_id: ByteArray,
  _oracle_asset_asset_name: ByteArray,
  governance_token_policy_id: ByteArray,
  governance_token_asset_name: ByteArray,
  charlie_specs: CharlieTokenSpecs,
) {
  //Allow to move Oracle NFT if governance have signed off.
  spend(
    _datum_opt: Option<Data>,
    _redeemer: Data,
    _input: OutputReference,
    self: Transaction,
  ) {
    //Governance approval (transaction signed by governance NFT holder)
    authorizer.authorize_via_nft_ownership(
      governance_token_policy_id,
      governance_token_asset_name,
      self.reference_inputs,
      self.withdrawals,
      self.extra_signatories,
    )
  }

  //Validate that n/m oracles have signed on this TX
  withdraw(redeemer: OracleRedeemer, _credential: Credential, self: Transaction) {
    let unique_signatures = list.unique(redeemer.signatures)

    when redeemer.data is {
      PriceDataCharlie {
        provider_ref_input_index,
        common,
        price_in_lovelaces,
        price_denominator,
      } -> {
        //Charlie 3 provides a utxo that keeps refreshing his value price and expiration, so we check that the redeemer that we are passing 
        //is parsing correct information from the main feed, in this way we can use the same withdraw oracle contract to read from our oracles or charlie3
        expect Some(charlie_input) =
          list.at(self.reference_inputs, provider_ref_input_index)
        expect InlineDatum(referenceDatum) = charlie_input.output.datum
        expect oracleDatum: OracleDatum = referenceDatum

        //informations coming from charli3
        let start_oracle = get_oracle_timestamp(oracleDatum)
        let end_oracle = get_expiry(oracleDatum.price_data)
        let price_oracle = get_oracle_price(oracleDatum)

        //for each assetname our contracts knows what token identifier should look for and also the mutlipliers to parse the datum from provider to our lovelace format
        let provider_info = get_oracle_config(charlie_specs, common.token)
        let token_provider_identifier = provider_info.1st
        let decimals = provider_info.2nd

        //token price of FLDT 0.35 ADA therefore is 350000 by charlie FLDT 6 decimals
        //therefore 1000000 unit FLDT = 350000 lovelace 
        //unitFLDT/lovelace=0.35
        //therefore we will write in redeemer 35 and 100 as divider
        //token price of SNEK is 0.003 SNEK/ADA therefore is 3000 by charlie SNEK 0 decimals
        //1 SNEK= 3000 lovelace
        //we will write in redeemer 3000 and 1 as divider
        //Raulito price is 0.20 and has 8 decimals
        //100000000 uraulito=200000
        //0.002 2/1000
        //redeemrprice*100000000/redemeerdivider=charli3
        //35*1000000/100 = charlie3
        //3000*1/1=charlie3
        and {
          quantity_of(
            charlie_input.output.value,
            token_provider_identifier,
            constants.assetname_identifier_charlie,
          ) == 1,
          common.valid_from >= start_oracle,
          common.valid_to <= end_oracle,
          price_in_lovelaces * math.pow(10, decimals) / price_denominator == price_oracle,
        }
      }
      _ -> {
        let valid_signatures =
          list.foldl(
            unique_signatures,
            0,
            fn(redem, valid_signatures) -> Int {
              expect Some(verification_key) =
                list.at(verification_keys, redem.key_position)
              if builtin.verify_ed25519_signature(
                verification_key,
                builtin.serialise_data(redeemer.data),
                redem.signature,
              ) {
                valid_signatures + 1
              } else {
                valid_signatures
              }
            },
          )
        valid_signatures >= threshold
      }
    }
  }

  else(_) {
    fail
  }
}
