use aiken/builtin
use aiken/collection/list
use cardano/address.{Credential}
use cardano/transaction.{OutputReference, Transaction}
use fluidtokens/nft_pointers
use fluidtokens/types/general.{Asset}
use fluidtokens/types/redeemer.{OracleRedeemer}

validator oracle(
  verification_keys: List<ByteArray>,
  threshold: Int,
  _oracle_asset: Asset,
  governance_token: Asset,
) {
  // Allow to move Oracle NFT if governance have signed off.
  spend(
    _datum_opt: Option<Data>,
    _redeemer: Data,
    _input: OutputReference,
    self: Transaction,
  ) {
    // Governance approval (transaction signed by governance NFT holder)
    nft_pointers.nft_validator(
      governance_token.policyId,
      governance_token.assetName,
      self.reference_inputs,
      self.withdrawals,
      self.extra_signatories,
    )
  }

  // Validate that n/m oracles have signed on this TX
  withdraw(
    redeemer: OracleRedeemer,
    _credential: Credential,
    _self: Transaction,
  ) {
    let unique_signatures = list.unique(redeemer.signatures)
    let valid_signatures =
      list.foldl(
        unique_signatures,
        0,
        fn(redem, valid_signatures) -> Int {
          expect Some(verification_key) =
            list.at(verification_keys, redem.key_position)
          if
          builtin.verify_ed25519_signature(
            verification_key,
            builtin.serialise_data(redeemer.data),
            redem.signature,
          ){
          
            valid_signatures + 1
          } else {
            valid_signatures
          }
        },
      )
    valid_signatures >= threshold
  }

  else(_) {
    fail
  }
}
