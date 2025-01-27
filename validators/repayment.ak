//All money to parties are sent here so they can withdraw them along with the repayment NFT.
//Without the repayment NFT this can be used for depositing other stuff too.
use aiken/collection/dict
use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Input, Output, Transaction, Withdraw}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/general.{Asset}
use fluidtokens/types/loan.{Claim, LoanWithdrawRedeemer, Recast, Repay}
use fluidtokens/types/pool.{Liquidation}
use fluidtokens/types/repayment.{
  RepaymentDatum, RepaymentDatumWithHash, RepaymentDatumWithToken,
  RepaymentMintRedeemer, RepaymentWithdrawRedeemer, WithdrawWithHash,
  WithdrawWithToken,
} as r
use fluidtokens/utils.{is_nft_spent, quantity_of_policy_id, safe_list_at}
use smart_tokens/utils.{get_inputs_from_smart_credential} as st_utils

validator repayment(
  configNFTPolicyId: PolicyId,
  configNFTAssetName: ByteArray,
) {
  //Repayment outputs are already checked by the loan validator, here we just ensure we don't mint additional undesired tokens
  //Burning is always allowed
  //Each output has a unique NFT
  mint(redeemer: RepaymentMintRedeemer, policy_id: PolicyId, self: Transaction) {
    let config =
      utils.get_config(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )

    let loanInputs =
      st_utils.get_inputs_from_smart_credential(
        self.inputs,
        Script(config.loanSpendScriptHash),
        Script(policy_id),
        config.smartTokensSpendScriptHash,
      )
    let repaymentOutputs =
      st_utils.get_outputs_to_smart_credential(
        self.outputs,
        Script(config.repaymentSpendScriptHash),
        Script(policy_id),
        config.smartTokensSpendScriptHash,
      )
    let mintedNFTs = dict.to_pairs(tokens(self.mint, policy_id))

    let loanWithdrawRedeemer =
      safe_list_at(self.redeemers, redeemer.loanWithdrawRedeemerIndex)
    expect loanWithdrawRedeemer.1st == Withdraw(Script(config.loanPolicyId))
    expect loanRedeemer: LoanWithdrawRedeemer = loanWithdrawRedeemer.2nd

    let expectedMintedNFTs =
      list.indexed_foldr(
        loanInputs,
        [],
        fn(index, input, result) {
          let loanRedeemerAction =
            safe_list_at(loanRedeemer.actionsForEachInput, index)

          let shouldBeConsidered =
            when loanRedeemerAction is {
              Claim { liquidationMode, equity, .. } -> {
                expect Liquidation { partialLiquidation, .. } = liquidationMode
                partialLiquidation && equity > 0
              }
              Repay { .. } -> True
              Recast { .. } -> True
              _ -> False
            }

          if shouldBeConsidered {
            let repaymentAssetName =
              utils.hash_output_ref(input.output_reference)
            let repaymentOutput = safe_list_at(repaymentOutputs, index)
            expect and {
                dict.size(assets.tokens(repaymentOutput.value, policy_id)) == 1,
                assets.quantity_of(
                  repaymentOutput.value,
                  policy_id,
                  repaymentAssetName,
                ) == 1,
              }
            list.push(result, Pair(repaymentAssetName, 1))
          } else {
            result
          }
        },
      )

    expectedMintedNFTs == mintedNFTs
  }

  withdraw(
    redeemer: RepaymentWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(policyId) = credential
    let config =
      utils.get_config(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let repaymentInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(config.repaymentSpendScriptHash),
        credential,
        config.smartTokensSpendScriptHash,
      )
    //As we loop through the inputs we DO NOT need to ensure that the number of actions is equal to the number of inputs
    list.indexed_foldr(
      repaymentInputs,
      True,
      fn(index, input, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: RepaymentDatum = inputDatum
        let redeemerAction = safe_list_at(redeemer.actionsForEachInput, index)

        let repaymentId = redeemerAction.2nd
        //Either the utxo doesn't have a repayment NFT OR it burns it
        let eventualRepaymentTokenBurnt = or {
            quantity_of_policy_id(input.output.value, policyId) == 0,
            and {
              quantity_of(input.output.value, policyId, repaymentId) == 1,
              quantity_of(self.mint, policyId, repaymentId) == -1,
            },
          }

        and {
          eventualRepaymentTokenBurnt,
          when redeemerAction.1st is {
            WithdrawWithToken(tokenInputIndex) -> {
              expect RepaymentDatumWithToken { ownerAsset, .. } = datum
              expect Some(tokenInput) = list.at(self.inputs, tokenInputIndex)
              is_nft_spent(
                ownerAsset.policyId,
                ownerAsset.assetName,
                tokenInput,
              )
            }
            WithdrawWithHash -> {
              expect RepaymentDatumWithHash { ownerAuth, .. } = datum
              authorize_action(
                create_auth(
                  ownerAuth,
                  self.inputs,
                  self.withdrawals,
                  self.extra_signatories,
                  self.mint,
                ),
              )
            }
          },
        }
      },
    )
  }

  else(_) {
    fail
  }
}
