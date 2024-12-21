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

    let loanInputOutRefsWithTheirActionAndLoanId =
      list.map3(
        self.inputs,
        loanRedeemer.actionsForEachInput,
        redeemer.loanIds,
        fn(input, action, loanId) {
          expect
            quantity_of(input.output.value, config.loanPolicyId, loanId) == 1
          (input.output_reference, action, loanId)
        },
      )

    let loanInputsWithTheirActionThatNeedRepaymentNFTMint =
      list.filter(
        loanInputOutRefsWithTheirActionAndLoanId,
        fn(loanInputAndAction) {
          when loanInputAndAction.2nd is {
            Claim(liquidationMode, remainingAmount, ..) -> {
              expect Liquidation { partialLiquidation, .. } = liquidationMode
              partialLiquidation && remainingAmount > 0
            }
            Repay(..) -> True
            Recast(..) -> True
            _ -> False
          }
        },
      )

    let expectedNFTMinted =
      list.map(
        loanInputsWithTheirActionThatNeedRepaymentNFTMint,
        fn(loanInputAndActionAndLoanId) {
          Pair(loanInputAndActionAndLoanId.3rd, 1)
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
    //Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
    expect length(repaymentInputs) == length(redeemer.actionsForEachInput)

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

        let repaymentNFTAssetName = redeemerAction.2nd
        //Either the utxo doesn't have a repayment nft OR it burns it
        let eventualRepaymentNFTBurnt = or {
            quantity_of_policy_id(self.mint, policyId) == 0,
            and {
              quantity_of(self.mint, policyId, repaymentNFTAssetName) == 1,
              quantity_of(self.mint, policyId, repaymentNFTAssetName) == -1,
            },
          }

        and {
          eventualRepaymentNFTBurnt,
          when redeemerAction.1st is {
            WithdrawWithToken(tokenInputIndex) -> {
              expect RepaymentDatumWithToken(_action, _data, ownerAsset) = datum
              expect Some(tokenInput) = list.at(self.inputs, tokenInputIndex)
              is_nft_spent(
                ownerAsset.policyId,
                ownerAsset.assetName,
                tokenInput,
              )
            }
            WithdrawWithHash(auth) -> {
              expect RepaymentDatumWithHash(_action, _data, ownerAuthHash) =
                datum
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
    )
  }

  else(_) {
    fail
  }
}
