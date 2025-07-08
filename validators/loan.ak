use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use cardano/address.{Credential, Script}
use cardano/assets.{PolicyId, tokens}
use cardano/transaction.{Input, Output, Transaction, Withdraw}
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
      utils.get_config_as_data_list(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let loanClaimActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 11))
    let loanRepayActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 12))
    let loanChangeCollateralActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 13))
    let loanRecastActionScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 14))

    let actionWithdrawScriptHash =
      when redeemer.actionType is {
        Claim { .. } -> loanClaimActionScriptHash
        Repay { .. } -> loanRepayActionScriptHash
        ChangeCollateral { .. } -> loanChangeCollateralActionScriptHash
        Recast { .. } -> loanRecastActionScriptHash
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
    utils.get_config_as_data_list(
      safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
      configNFTPolicyId,
      configNFTAssetName,
    )
  let smartTokensSpendScriptHash =
    builtin.un_b_data(utils.safe_list_at(config, 0))
  let loanSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 10))
  let poolSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 8))
  let poolPolicyId = builtin.un_b_data(utils.safe_list_at(config, 2))
  let requestSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 9))
  let requestPolicyId = builtin.un_b_data(utils.safe_list_at(config, 3))

  let originInputs =
    if redeemer.isPoolOrigin {
      st_utils.get_inputs_from_smart_credential(
        self.inputs,
        Script(poolSpendScriptHash),
        Script(poolPolicyId),
        smartTokensSpendScriptHash,
      )
    } else {
      st_utils.get_inputs_from_smart_credential(
        self.inputs,
        Script(requestSpendScriptHash),
        Script(requestPolicyId),
        smartTokensSpendScriptHash,
      )
    }
  let loanOutputs =
    st_utils.get_outputs_to_smart_credential(
      self.outputs,
      Script(loanSpendScriptHash),
      Script(policy_id),
      smartTokensSpendScriptHash,
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
        expect poolWithdrawRedeemer.1st == Withdraw(Script(poolPolicyId))
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
        expect requestWithdrawRedeemer.1st == Withdraw(Script(requestPolicyId))
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
