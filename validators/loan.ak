use aiken/collection/dict
use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/assets.{PolicyId, tokens}
use cardano/transaction.{Input, Output, OutputReference, Transaction, Withdraw}
use fluidtokens/types/config.{ConfigDatum}
use fluidtokens/types/loan.{
  ChangeCollateral, Claim, LoanMintRedeemer, LoanWithdrawRedeemer, Recast, Repay,
} as l
use fluidtokens/types/pool.{Borrow, PoolWithdrawRedeemer}
use fluidtokens/types/request.{Lend, RequestWithdrawRedeemer}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils as st_utils

validator loan(configNFTPolicyId: ByteArray, configNFTAssetName: ByteArray) {
  //Loan outputs are already checked by the pool validator, here we just ensure we don't mint additional undesired tokens
  //Burning is always allowed
  //Each output has a unique NFT
  mint(redeemer: LoanMintRedeemer, policy_id: PolicyId, self: Transaction) {
    check_mint(self, redeemer, policy_id)
  }

  withdraw(
    redeemer: LoanWithdrawRedeemer,
    _credential: Credential,
    self: Transaction,
  ) {
    let config =
      utils.get_config(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )

    let actionWithdrawScriptHash =
      when redeemer.actionType is {
        Claim { .. } -> config.loanClaimActionScriptHash
        Repay { .. } -> config.loanRepayActionScriptHash
        ChangeCollateral { .. } -> config.loanChangeCollateralActionScriptHash
        Recast { .. } -> config.loanRecastActionScriptHash
      }

    list.any(
      self.withdrawals,
      fn(withdrawal) {
        when withdrawal is {
          Pair(Script(scriptHash), _amnt) ->
            scriptHash == actionWithdrawScriptHash
          _ -> False
        }
      },
    )
  }

  else(_) {
    fail
  }
}

fn check_mint(
  self: Transaction,
  redeemer: LoanMintRedeemer,
  policy_id: PolicyId,
) {
  let config =
    utils.get_config(
      safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
      configNFTPolicyId,
      configNFTAssetName,
    )

  let originInputs =
    if redeemer.isPoolOrigin {
      st_utils.get_inputs_from_smart_credential(
        self.inputs,
        Script(config.poolSpendScriptHash),
        Script(config.poolPolicyId),
        config.smartTokensSpendScriptHash,
      )
    } else {
      st_utils.get_inputs_from_smart_credential(
        self.inputs,
        Script(config.requestSpendScriptHash),
        Script(config.requestPolicyId),
        config.smartTokensSpendScriptHash,
      )
    }
  let loanOutputs =
    st_utils.get_outputs_to_smart_credential(
      self.outputs,
      Script(config.loanSpendScriptHash),
      Script(policy_id),
      config.smartTokensSpendScriptHash,
    )
  //We exclude the burnt tokens (quantity < 0) as they are always allowed
  let mintedNFTs =
    list.filter(
      dict.to_pairs(tokens(self.mint, policy_id)),
      fn(tokenPair) { tokenPair.2nd > 0 },
    )

  if list.length(mintedNFTs) > 0 {
    let expectedMintedNFTs =
      if redeemer.isPoolOrigin {
        let poolWithdrawRedeemer =
          safe_list_at(self.redeemers, redeemer.originWithdrawRedeemerIndex)
        expect poolWithdrawRedeemer.1st == Withdraw(Script(config.poolPolicyId))
        expect poolRedeemer: PoolWithdrawRedeemer = poolWithdrawRedeemer.2nd
        list.indexed_foldr(
          originInputs,
          [],
          fn(index, input, result) {
            let poolRedeemerAction =
              safe_list_at(poolRedeemer.actionsForEachInput, index)

            when poolRedeemerAction is {
              Borrow { .. } -> {
                let loanAssetName =
                  utils.hash_output_ref(input.output_reference)
                let loanOutput = safe_list_at(loanOutputs, index)
                expect and {
                    input.output_reference.output_index <= 255,
                    dict.size(assets.tokens(loanOutput.value, policy_id)) == 1,
                    assets.quantity_of(
                      loanOutput.value,
                      policy_id,
                      loanAssetName,
                    ) == 1,
                  }
                list.push(result, Pair(loanAssetName, 1))
              }
              _ -> result
            }
          },
        )
      } else {
        let requestWithdrawRedeemer =
          safe_list_at(self.redeemers, redeemer.originWithdrawRedeemerIndex)
        expect
          requestWithdrawRedeemer.1st == Withdraw(
            Script(config.requestPolicyId),
          )
        expect requestRedeemer: RequestWithdrawRedeemer =
          requestWithdrawRedeemer.2nd
        list.indexed_foldr(
          originInputs,
          [],
          fn(index, input, result) {
            let requestRedeemerAction =
              safe_list_at(requestRedeemer.actionsForEachInput, index)

            when requestRedeemerAction is {
              Lend { .. } -> {
                let loanAssetName =
                  utils.hash_output_ref(input.output_reference)
                let loanOutput = safe_list_at(loanOutputs, index)
                expect and {
                    input.output_reference.output_index <= 255,
                    dict.size(assets.tokens(loanOutput.value, policy_id)) == 1,
                    assets.quantity_of(
                      loanOutput.value,
                      policy_id,
                      loanAssetName,
                    ) == 1,
                  }
                list.push(result, Pair(loanAssetName, 1))
              }
              _ -> result
            }
          },
        )
      }

    list.sort(expectedMintedNFTs, utils.pairs_ordering) == mintedNFTs
  } else {
    True
  }
}
