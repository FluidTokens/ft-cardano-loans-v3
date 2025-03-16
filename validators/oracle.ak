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
use fluidtokens/utils.{get_oracle_config, get_oracle_info}

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

        //Information coming from charli3
        let (price_oracle, start_oracle, end_oracle) =
          get_oracle_info(oracleDatum.price_data)

        //For each assetname our contracts knows what token identifier should look for and also the mutlipliers to parse the datum from provider to our lovelace format
        let provider_info = get_oracle_config(charlie_specs, common.token)
        let token_provider_identifier = provider_info.1st
        let decimals = provider_info.2nd

        //Suppose token price of 1 FLDT is 0.35 ADA
        //Charlie says 1 FLDT = 350000 lovelace and that it has 6 decimals
        //Therefore 1000000 unitFLDT = 350000 lovelace 
        //unitFLDT/lovelace=0.35
        //So we will write in the redeemer 35 as value and 100 as divider.
        //Another example, token price of 1 SNEK is 0.003 ADA
        //Charlie says 1 SNEK = 3000 lovelace and that it has 0 decimals
        //Therefore 1 unitSNEK = 3000 lovelace
        //So we will write in redeemer 3000 and 1 as divider.
        //Again, token price of 1 Raulito  is 0.20 ADA
        //Charlie says 1 Raulito = 200000 lovelace and that it has 8 decimals
        //Therefore 100000000 unitRaulito = 200000 lovelace
        //1 unitRaulito = 0.002 lovelace
        //So we will write in redeemer 2 and 1000 as divider.
        //The equality that must hold then it's:
        //redeemer_price*charlie3_token_decimals/redeemer_divider == charlie3_price_oracle
        and {
          quantity_of(
            charlie_input.output.value,
            token_provider_identifier,
            constants.charlie_identifier_asset_name,
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
