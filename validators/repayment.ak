//All money to parties are sent here so they can withdraw them along with the repayment NFT.
//Without the repayment NFT this can be used for depositing other stuff too.
use aiken/collection/dict
use aiken/collection/list.{length}
use aiken/option
use aiken/primitive/bytearray
use cardano/address.{Credential, Script}
use cardano/assets.{PolicyId, quantity_of, tokens}
use cardano/transaction.{
  InlineDatum, Input, Output, Transaction, Withdraw, find_input,
}
use fluidtokens/authorizer.{authorize_action}
use fluidtokens/types/datum.{
  Liquidation, RepaymentDatum, RepaymentDatumWithHash, RepaymentDatumWithToken,
}
use fluidtokens/types/general.{Asset, Authorization}
use fluidtokens/types/redeemer.{
  Claim, LoanWithdrawRedeemer, Recast, Repay, RepaymentMintRedeemer,
  RepaymentWithdrawRedeemer, WithdrawWithHash, WithdrawWithToken,
}
use fluidtokens/utils.{is_nft_spent, quantity_of_policy_id, safe_list_at}
use smart_tokens/utils.{get_inputs_from_sc} as st_utils

validator repayment(configAsset: Asset) {
  //Repayment outputs are already checked by the loan validator, here we just ensure we don't mint additional undesired tokens
  //Burning is always allowed
  //Each output has a unique NFT
  mint(redeemer: RepaymentMintRedeemer, policy_id: PolicyId, self: Transaction) {
    let config =
      utils.get_config(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configAsset.policyId,
        configAsset.assetName,
      )

    let inputRefHash = utils.hash_output_ref(redeemer.inputRef)
    let repaymentOutputs =
      st_utils.get_outputs_to_sc(
        self.outputs,
        config.repaymentSpendScriptHash,
        config.smartTokensSpendScriptHash,
      )
    let isInputRefSpent =
      option.is_some(find_input(self.inputs, redeemer.inputRef))
    let mintedNFTs = dict.to_pairs(tokens(self.mint, policy_id))

    let loanWithdrawRedeemer =
      safe_list_at(self.redeemers, redeemer.loanWithdrawRedeemerIndex)
    expect loanWithdrawRedeemer.1st == Withdraw(Script(config.loanPolicyId))
    expect loanRedeemer: LoanWithdrawRedeemer = loanWithdrawRedeemer.2nd

    let expectedMintedNFTs =
      list.indexed_foldr(
        list.filter(
          loanRedeemer.actionsForEachInput,
          fn(action) {
            when action is {
              Claim { liquidationMode, equity, .. } -> {
                expect Liquidation { partialLiquidation, .. } = liquidationMode
                if partialLiquidation && equity > 0 {
                  True
                } else {
                  False
                }
              }
              Repay { .. } -> True
              Recast { .. } -> True
              _ -> False
            }
          },
        ),
        [],
        fn(index, _action, result) {
          let repaymentAssetName =
            bytearray.push(bytearray.drop(inputRefHash, 1), index)
          expect Some(output) = list.at(repaymentOutputs, index)
          expect and {
              dict.size(assets.tokens(output.value, policy_id)) == 1,
              assets.quantity_of(output.value, policy_id, repaymentAssetName) == 1,
            }
          list.push(result, Pair(repaymentAssetName, 1))
        },
      )

    and {
      isInputRefSpent,
      expectedMintedNFTs == mintedNFTs,
    }
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
      get_inputs_from_sc(
        self.inputs,
        config.repaymentSpendScriptHash,
        config.smartTokensSpendScriptHash,
      )
    and {
      //Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
      length(repaymentInputs) == length(redeemer.actionsForEachInput),
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
              WithdrawWithHash(auth) -> {
                expect RepaymentDatumWithHash { ownerAuthHash, .. } = datum
                and {
                  ownerAuthHash == auth.hash,
                  authorize_action(auth),
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
