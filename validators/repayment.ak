//All money to parties are sent here so they can withdraw them
use aiken/collection/dict
use aiken/collection/list.{length}
use cardano/address.{Credential, Script}
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Input, Output, Transaction, Withdraw}
use types/datum.{
  Liquidation, RepaymentDatum, RepaymentDatumWithHash, RepaymentDatumWithToken,
}
use types/general.{Asset}
use types/redeemer.{
  Claim, LoanWithdrawRedeemer, Recast, Repay, RepaymentMintRedeemer,
  RepaymentWithdrawRedeemer, WithdrawWithHash, WithdrawWithToken,
}
use utils.{
  authorize_action, get_inputs_from_sc_or_delegated_to_sc, is_nft_spent,
  quantity_of_policy_id, safe_list_at,
}

validator repayment(configAsset: Asset) {
  //Repayment outputs are already checked by the loan validator, here we just ensure we don't mint additional undesired tokens
  //Burning is always allowed
  //These are NOT NFTs, as in case of multiple repayments for the same loan (recast, installments, etc.) they have the same AssetName
  //which is the loanId!
  mint(redeemer: RepaymentMintRedeemer, policy_id: PolicyId, self: Transaction) {
    let config =
      utils.get_config(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configAsset.policyId,
        configAsset.assetName,
      )

    let loanWithdrawRedeemer =
      safe_list_at(self.redeemers, redeemer.loanWithdrawRedeemerIndex)
    expect loanWithdrawRedeemer.1st == Withdraw(Script(config.loanPolicyId))
    expect loanRedeemer: LoanWithdrawRedeemer = loanWithdrawRedeemer.2nd

    //Loan validator already ensures that the actions are in input order, same length and that every loanId is correct
    let expectedNFTMinted =
      list.foldl(
        loanRedeemer.actionsForEachInput,
        [],
        fn(action, result) {
          when action is {
            Claim { liquidationMode, equity, loanId, .. } -> {
              expect Liquidation { partialLiquidation, .. } = liquidationMode
              if partialLiquidation && equity > 0 {
                list.push(result, Pair(loanId, 1))
              } else {
                result
              }
            }
            Repay { loanId, .. } -> list.push(result, Pair(loanId, 1))
            Recast { loanId, .. } -> list.push(result, Pair(loanId, 1))
            _ -> result
          }
        },
      )

    //We check only minted tokens as burning is always allowed
    let mintedTokens =
      list.filter(
        dict.to_pairs(tokens(self.mint, policy_id)),
        fn(token) { token.2nd > 0 },
      )
    expectedNFTMinted == mintedTokens
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
        configAsset.policyId,
        configAsset.assetName,
      )
    let repaymentInputs =
      get_inputs_from_sc_or_delegated_to_sc(
        self.inputs,
        config.repaymentSpendScriptHash,
      )
    and {
      //Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
      length(repaymentInputs) == length(redeemer.actionsForEachInput),
      list.indexed_foldr(
        repaymentInputs,
        True,
        fn(index, inputAndCIP113Control, result) {
          //As all inputs must return True, if any of previous input returned False, then fail
          //The last input is not checked but will return its value at the end, so if False withdraw will fail
          expect result

          let input = inputAndCIP113Control.1st
          expect InlineDatum(inputDatum) = input.output.datum
          expect datum: RepaymentDatum = inputDatum
          let redeemerAction = safe_list_at(redeemer.actionsForEachInput, index)

          let repaymentId = redeemerAction.2nd
          //Either the utxo doesn't have a repayment nft OR it burns it
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
              WithdrawWithHash(auth) -> {
                expect RepaymentDatumWithHash { ownerAuthHash, .. } = datum
                and {
                  ownerAuthHash == auth.hash,
                  authorize_action(
                    auth,
                    self.inputs,
                    self.withdrawals,
                    self.extra_signatories,
                    self.mint,
                  ),
                }
              }
            },
          }
        },
      ),
    }
  }

  else(_) {
    fail
  }
}
