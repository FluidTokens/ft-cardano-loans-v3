use aiken/builtin
//All money to parties are sent here so they can withdraw them along with the repayment NFT.
//Without the repayment NFT this can be used for depositing other stuff too.
use aiken/collection/dict
use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Input, Output, Transaction, Withdraw}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/types/general.{Asset, Liquidation}
use fluidtokens/types/loan.{
  ChangeCollateral, Claim, ClaimData, LoanClaimActionWithdrawRedeemer,
  LoanWithdrawRedeemer, Recast, Repay,
}
use fluidtokens/types/repayment.{
  RepaymentDatum, RepaymentDatumWithHash, RepaymentDatumWithToken,
  RepaymentMintRedeemer, RepaymentWithdrawRedeemer, WithdrawWithHash,
  WithdrawWithToken,
} as r
use fluidtokens/utils.{is_nft_in_output, quantity_of_policy_id, safe_list_at}
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
      utils.get_config_as_data_list(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let smartTokensSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 0))
    let loanSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 10))
    let loanPolicyId = builtin.un_b_data(utils.safe_list_at(config, 2))
    let loanClaimActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 11))
    let loanInputs =
      st_utils.get_inputs_from_smart_credential(
        self.inputs,
        Script(loanSpendScriptHash),
        Script(loanPolicyId),
        smartTokensSpendScriptHash,
      )

    //We exclude the burnt tokens (quantity < 0) as they are always allowed
    let mintedNFTs =
      list.filter(
        dict.to_pairs(tokens(self.mint, policy_id)),
        fn(tokenPair) {
          expect tokenPair.2nd < 0 || tokenPair.2nd == 1
          tokenPair.2nd > 0
        },
      )

    if list.length(mintedNFTs) > 0 {
      let expectedMintedNFTs = {
        let loanWithdrawRedeemer =
          safe_list_at(self.redeemers, redeemer.loanWithdrawRedeemerIndex)
        expect loanWithdrawRedeemer.1st == Withdraw(Script(loanPolicyId))
        expect loanRedeemer: LoanWithdrawRedeemer = loanWithdrawRedeemer.2nd

        when loanRedeemer.actionType is {
          Claim -> {
            let loanClaimActionWithdrawRedeemer =
              safe_list_at(
                self.redeemers,
                redeemer.loanClaimActionWithdrawRedeemerIndex,
              )
            expect
              loanClaimActionWithdrawRedeemer.1st == Withdraw(
                Script(loanClaimActionScriptHash),
              )
            expect loanClaimActionRedeemer: LoanClaimActionWithdrawRedeemer =
              loanClaimActionWithdrawRedeemer.2nd
            list.indexed_foldr(
              loanInputs,
              [],
              fn(index, input, result) {
                let ClaimData { liquidationMode, equity, .. } =
                  safe_list_at(
                    loanClaimActionRedeemer.actionsForEachInput,
                    index,
                  )
                let repaymentAssetName =
                  utils.hash_output_ref(input.output_reference)
                expect Liquidation { partialLiquidationPenaltyPerMille, .. } =
                  liquidationMode
                expect partialLiquidationPenaltyPerMille >= 0 && equity > 0
                list.push(result, Pair(repaymentAssetName, 1))
              },
            )
          }
          Repay ->
            list.foldr(
              loanInputs,
              [],
              fn(input, result) {
                let repaymentAssetName =
                  utils.hash_output_ref(input.output_reference)
                list.push(result, Pair(repaymentAssetName, 1))
              },
            )
          ChangeCollateral -> fail
          Recast ->
            list.foldr(
              loanInputs,
              [],
              fn(input, result) {
                let repaymentAssetName =
                  utils.hash_output_ref(input.output_reference)
                list.push(result, Pair(repaymentAssetName, 1))
              },
            )
        }
      }

      list.sort(expectedMintedNFTs, utils.pairs_ordering) == mintedNFTs
    } else {
      True
    }
  }

  //TODO: This is OLD, the repayment doesn't need to go here anymore
  withdraw(
    redeemer: RepaymentWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(policyId) = credential
    let config =
      utils.get_config_as_data_list(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let smartTokensSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 0))
    let repaymentSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 15))
    let repaymentInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(repaymentSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
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
            WithdrawWithToken(tokenOutputIndex) -> {
              expect RepaymentDatumWithToken { ownerAsset, .. } = datum
              let tokenOutput =
                utils.safe_list_at(self.outputs, tokenOutputIndex)
              is_nft_in_output(
                ownerAsset.policyId,
                ownerAsset.assetName,
                tokenOutput,
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
