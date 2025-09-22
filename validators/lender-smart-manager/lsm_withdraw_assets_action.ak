use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto
use aiken/interval.{Finite, Interval}
use aiken/math/rational.{Rational}
use aiken/primitive/bytearray
use cardano/address.{Address, Credential, Script}
use cardano/assets.{add, flatten, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use fluidtokens/authorizer.{authorize_action, create_auth}
use fluidtokens/constants
use fluidtokens/finance
use fluidtokens/oracle.{retrieve_oracle_data}
use fluidtokens/types/general.{Asset, CollateralAsset}
use fluidtokens/types/lender_smart_wallet.{
  Compound, LSMWithdrawAssetsWithdrawRedeemer, LenderSmartWalletDatum,
  LenderSmartWalletWithdrawRedeemer, Liquidate, LiquidateAndConvert,
  LiquidateAndPayInAdvance, LiquidateConvertAndCompound,
  LiquidatePayInAdvanceAndCompound, WithdrawAssets, WithdrawBonds,
} as lsw
use fluidtokens/types/loan.{
  LoanDatum, LoanRepayActionWithdrawRedeemer, LoanRepaymentData,
} as l
use fluidtokens/types/minswap_info.{MinswapV2Info}
use fluidtokens/types/minswap_v2_types as minswap
use fluidtokens/types/pool.{PoolDatum}
use fluidtokens/types/pool_smart_manager.{PoolSmartManagerDatum}
use fluidtokens/types/repayment.{RepaymentDatumWithToken} as r
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, get_outputs_to_smart_credential,
} as st_utils

validator actionValidator(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
  lenderSmartWalletSpendScriptHash: ByteArray,
) {
  withdraw(
    redeemer: LSMWithdrawAssetsWithdrawRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    let config =
      utils.get_config_as_data_list(
        safe_list_at(self.reference_inputs, redeemer.configRefInputIndex),
        configNFTPolicyId,
        configNFTAssetName,
      )
    let smartTokensSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 0))
    let lswInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(lenderSmartWalletSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )
    let (lenderBondInputs, lswAssetsInputs) =
      list.partition(
        lswInputs,
        fn(input) {
          expect InlineDatum(inputDatum) = input.output.datum
          if inputDatum is LenderSmartWalletDatum {
            True
          } else {
            //We still expect the datum to be RepaymentDatumWithToken here
            False
          }
        },
      )

    and {
      list.indexed_foldr(
        lswAssetsInputs,
        True,
        fn(index, input, result) {
          //As all inputs must return True, if any of previous input returned False, then fail
          //The last input is not checked but will return its value at the end, so if False withdraw will fail
          expect result

          expect InlineDatum(inputDatum) = input.output.datum
          expect RepaymentDatumWithToken { ownerAsset, .. } = inputDatum

          //TODO Vulnerability
          let lenderBondIndex =
            safe_list_at(redeemer.lenderBondInputIndexes, index)

          let lenderBondInput = safe_list_at(lswInputs, lenderBondIndex)

          quantity_of(
            lenderBondInput.output.value,
            ownerAsset.policyId,
            ownerAsset.assetName,
          ) == 1
        },
      ),
      list.foldr(
        lenderBondInputs,
        True,
        fn(lenderBondInput, result) {
          //As all inputs must return True, if any of previous input returned False, then fail
          //The last input is not checked but will return its value at the end, so if False withdraw will fail
          expect result

          expect InlineDatum(inputLenderBondDatum) =
            lenderBondInput.output.datum
          expect LenderSmartWalletDatum { lenderAuth, .. } =
            inputLenderBondDatum

          authorize_action(
            create_auth(
              lenderAuth,
              self.inputs,
              self.withdrawals,
              self.extra_signatories,
              self.mint,
            ),
          )
        },
      ),
    }
  }

  else(_) {
    fail
  }
}
