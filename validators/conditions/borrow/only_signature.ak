use aiken/builtin
use aiken/cbor.{serialise}
use aiken/collection/list
use aiken/crypto.{
  Blake2b_256, Hash, Signature, VerificationKey, VerificationKeyHash,
  blake2b_224, blake2b_256, verify_ed25519_signature,
}
use aiken/interval.{Finite, Interval, IntervalBound}
use cardano/address.{Address, Credential, Script}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, ValidityRange,
  Withdraw,
}
use fluidtokens/types/pool.{
  Borrow, BorrowData, PoolBorrowActionWithdrawRedeemer, PoolWithdrawRedeemer,
}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{get_inputs_from_smart_credential} as st_utils

pub type PermissionedDatum {
  whitelisted_oracles: List<VerificationKeyHash>,
}

pub type TokenData {
  // The users DID Identifier
  did: ByteArray,
  //The users public key
  user_key: VerificationKeyHash,
  //The Address of the pool input
  origin_output_reference: OutputReference,
  //Blake2b-256 hash of the cbor serialized borrow action
  borrow_action_hash: Hash<Blake2b_256, Data>,
  //A valid range
  validity_range: ValidityRange,
  //The public key of the oracle
  oracle_key: VerificationKey,
}

pub type ComplianceToken {
  token: TokenData,
  //A signature from the compliance oracle for serialized TokenData
  oracle_signature: Signature,
}

pub type KycTokenWithdrawRedeemer {
  poolWithdrawRedeemerIndex: Int,
  poolBorrowWithdrawRedeemerIndex: Int,
  complianceForEachInput: List<ComplianceToken>,
}

validator kyc_token(
  poolPolicyId: ByteArray,
  poolSpendScriptHash: ByteArray,
  poolBorrowActionScriptHash: ByteArray,
  smartTokensSpendScriptHash: ByteArray,
) {
  withdraw(
    redeemer: KycTokenWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(scriptHash) = credential

    let poolWithdrawRedeemer =
      safe_list_at(self.redeemers, redeemer.poolWithdrawRedeemerIndex)
    expect poolWithdrawRedeemer.1st == Withdraw(Script(poolPolicyId))
    expect PoolWithdrawRedeemer { actionType, .. } = poolWithdrawRedeemer.2nd
    //Pools must do borrow action
    expect actionType == Borrow

    let poolBorrowWithdrawRedeemer =
      safe_list_at(self.redeemers, redeemer.poolBorrowWithdrawRedeemerIndex)
    expect
      poolBorrowWithdrawRedeemer.1st == Withdraw(
        Script(poolBorrowActionScriptHash),
      )
    expect PoolBorrowActionWithdrawRedeemer { actionsForEachInput, .. } =
      poolBorrowWithdrawRedeemer.2nd
    //TODO Get all loan outputs and ensure they have borrowerAuth of type CardanoSignature
    False
  }

  else(_) {
    fail
  }
}
