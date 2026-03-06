use aiken/builtin
use aiken/collection/list.{length}
use aiken/crypto
use aiken/interval.{Finite, Interval}
use aiken/math/rational
use cardano/address.{Address, Credential, Script}
use cardano/assets.{flatten, quantity_of}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use fluidtokens/constants
use fluidtokens/finance.{
  get_needed_collateral_with_oracles, get_needed_collateral_without_oracles,
}
use fluidtokens/oracle.{retrieve_oracle_data}
use fluidtokens/types/general.{PerpetualLoan}
use fluidtokens/types/loan.{LoanDatum} as l
use fluidtokens/types/pool.{
  PoolDatum, PoolSellLenderPositionActionWithdrawRedeemer, SellingLenderBondInfo,
}
use fluidtokens/utils.{safe_list_at, validity_range_within_an_hour}
use smart_tokens/utils.{get_inputs_from_smart_credential} as st_utils

validator pool_sell_lender_position_action(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  withdraw(
    redeemer: PoolSellLenderPositionActionWithdrawRedeemer,
    _credential: Credential,
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
    let poolSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 8))
    let poolPolicyId = builtin.un_b_data(utils.safe_list_at(config, 2))
    let loanSpendScriptHash = builtin.un_b_data(utils.safe_list_at(config, 10))
    let loanPolicyId = builtin.un_b_data(utils.safe_list_at(config, 6))
    let lenderBondPolicyId = builtin.un_b_data(utils.safe_list_at(config, 5))
    let poolInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(poolSpendScriptHash),
        Script(poolPolicyId),
        smartTokensSpendScriptHash,
      )
    let loanRefInputs =
      get_inputs_from_smart_credential(
        self.reference_inputs,
        Script(loanSpendScriptHash),
        Script(loanPolicyId),
        smartTokensSpendScriptHash,
      )

    //As we loop through the inputs we DO NOT need to ensure that the number of actions is equal to the number of inputs
    utils.indexed_all(
      poolInputs,
      fn(index, poolInput) {
        expect InlineDatum(poolInputDatum) = poolInput.output.datum
        expect poolDatum: PoolDatum = poolInputDatum
        let redeemerAction = safe_list_at(redeemer.actionsForEachInput, index)
        let principalSpent =
          list.foldr(
            redeemerAction.lenderBondsInfo,
            0,
            fn(lenderBondInfo, result) {
              let SellingLenderBondInfo {
                lenderBondInputIndex,
                lenderBondAssetName,
                loanRefInputIndex,
                outputWithLenderTokenIndex,
                poolCollateralIndex,
                collateralOracleRefInputIndex,
                principalOracleRefInputIndex,
              } = lenderBondInfo
              let lenderBondInput =
                safe_list_at(self.inputs, lenderBondInputIndex)
              let loanRefInput = safe_list_at(loanRefInputs, loanRefInputIndex)
              let outputWithLenderToken =
                safe_list_at(self.outputs, outputWithLenderTokenIndex)
              expect InlineDatum(loanRefInputDatum) = loanRefInput.output.datum
              expect loanDatum: LoanDatum = loanRefInputDatum
              expect InlineDatum(outputWithLenderTokenDatum) =
                outputWithLenderToken.datum
              //The value of the loan is the current borrowed principal
              let loanValueInPrincipal = loanDatum.principalAmount

              expect and {
                  //Lender bond input must have the lender bond
                  quantity_of(
                    lenderBondInput.output.value,
                    lenderBondPolicyId,
                    lenderBondAssetName,
                  ) == 1,
                  //Loan NFT AssetName must be the same of the lender bond
                  quantity_of(
                    loanRefInput.output.value,
                    loanPolicyId,
                    lenderBondAssetName,
                  ) == 1,
                  //Loan must have the same params of this pool and a LTV >= of the one set in this pool
                  is_loan_compatible_with_pool(
                    loanDatum,
                    poolDatum,
                    loanValueInPrincipal,
                    poolCollateralIndex,
                    rational.round(
                      finance.get_collateral_amount(
                        loanRefInput.output.value,
                        loanDatum.collateral,
                      ),
                    ),
                    collateralOracleRefInputIndex,
                    principalOracleRefInputIndex,
                    self,
                  ),
                  //The bond output must go to the specified address
                  outputWithLenderToken.address == poolDatum.lenderBondAddress,
                  //The bond output must have the requested InlineDatum
                  crypto.blake2b_256(
                    builtin.serialise_data(outputWithLenderTokenDatum),
                  ) == poolDatum.lenderBondInlineDatumHash,
                  //The bond output must contain the bond
                  quantity_of(
                    outputWithLenderToken.value,
                    lenderBondPolicyId,
                    lenderBondAssetName,
                  ) == 1,
                  //Avoid dossing the bond output
                  length(flatten(outputWithLenderToken.value)) <= 5,
                }

              result + loanValueInPrincipal
            },
          )
        let remainingPrincipalAmountAfterSelling =
          quantity_of(
            poolInput.output.value,
            poolDatum.commonData.principalAsset.policyId,
            poolDatum.commonData.principalAsset.assetName,
          ) - principalSpent
        and {
          quantity_of(
            poolInput.output.value,
            poolPolicyId,
            redeemerAction.poolId,
          ) == 1,
          validity_range_within_an_hour(self),
          //Either the pool must be closed or it must return with the remaining liquidity
          or {
            and {
              remainingPrincipalAmountAfterSelling == 0,
              quantity_of(self.mint, poolPolicyId, redeemerAction.poolId) == -1,
            },
            and {
              remainingPrincipalAmountAfterSelling > 0,
              validate_eventual_output_to_pool(
                safe_list_at(self.outputs, index),
                poolDatum,
                remainingPrincipalAmountAfterSelling,
                poolPolicyId,
                redeemerAction.poolId,
                poolInput.output.address,
                length(flatten(poolInput.output.value)),
              ),
            },
          },
        }
      },
    )
  }

  else(_) {
    fail
  }
}

//Expects remainingPrincipalAmountAfterSelling > 0
fn validate_eventual_output_to_pool(
  output: Output,
  datum: PoolDatum,
  remainingPrincipalAmountAfterSelling: Int,
  poolPolicyId: ByteArray,
  poolId: ByteArray,
  poolInputOutputAddress: Address,
  poolInputAssetsLength: Int,
) {
  expect InlineDatum(outputDatum) = output.datum

  let containsCorrectAmount =
    quantity_of(
      output.value,
      datum.commonData.principalAsset.policyId,
      datum.commonData.principalAsset.assetName,
    ) == remainingPrincipalAmountAfterSelling

  let containsPoolNFT = quantity_of(output.value, poolPolicyId, poolId) == 1

  let isDatumCorrect = builtin.equals_data(outputDatum, datum)

  let dosProtection = length(flatten(output.value)) == poolInputAssetsLength

  let correctDestination = poolInputOutputAddress == output.address

  and {
    correctDestination,
    isDatumCorrect,
    containsPoolNFT,
    containsCorrectAmount,
    dosProtection,
  }
}

fn is_loan_compatible_with_pool(
  loanDatum: LoanDatum,
  poolDatum: PoolDatum,
  loanValueInPrincipal: Int,
  collateralIndex: Int,
  loanCollateralAmount: Int,
  collateralOracleRefInputIndex: Int,
  principalOracleRefInputIndex: Int,
  self: Transaction,
) {
  expect (Finite(validFrom), Finite(validTo)) =
    (
      self.validity_range.lower_bound.bound_type,
      self.validity_range.upper_bound.bound_type,
    )
  let poolCollateral =
    safe_list_at(poolDatum.collateralOptions, collateralIndex)
  expect Some(minCollateral) =
    rational.new(
      safe_list_at(poolDatum.minCollateral, collateralIndex),
      safe_list_at(poolDatum.minCollateralDivider, collateralIndex),
    )

  let neededCollateral =
    if poolDatum.dynamicCollateralPrice {
      let collateralOracleRefInput =
        safe_list_at(self.reference_inputs, collateralOracleRefInputIndex)
      let chosenCollateralOracleToken = poolCollateral.oracleTokenAsset
      expect Some(collateralOraclePriceFeed) =
        retrieve_oracle_data(
          collateralOracleRefInput.output.address.payment_credential,
          collateralOracleRefInput.output.value,
          self.redeemers,
          validFrom,
          validTo,
          chosenCollateralOracleToken.policyId,
          chosenCollateralOracleToken.assetName,
          poolCollateral.policyId,
          poolCollateral.maybeAssetName,
        )
      let principalOracleRefInput =
        safe_list_at(self.reference_inputs, principalOracleRefInputIndex)
      expect Some(principalOraclePriceFeed) =
        retrieve_oracle_data(
          principalOracleRefInput.output.address.payment_credential,
          principalOracleRefInput.output.value,
          self.redeemers,
          validFrom,
          validTo,
          poolDatum.commonData.principalOracleAsset.policyId,
          poolDatum.commonData.principalOracleAsset.assetName,
          poolDatum.commonData.principalAsset.policyId,
          Some(poolDatum.commonData.principalAsset.assetName),
        )
      get_needed_collateral_with_oracles(
        loanValueInPrincipal,
        minCollateral,
        principalOraclePriceFeed,
        collateralOraclePriceFeed,
      )
    } else {
      get_needed_collateral_without_oracles(loanValueInPrincipal, minCollateral)
    }
  and {
    //Permissioned pools CANNOT do this action
    poolDatum.permissionedConditionScriptHash == constants.no_permissioned_condition,
    //If the loan has a higher interest rate of the pool, the pool owner is happy to receive more.
    //For Perpetuals, the current interest rate is the one we are interested in, so the loan can
    //be sold even if the original interest rate was lower than the one of the pool.
    when loanDatum.repaymentMode is {
      PerpetualLoan { apyIncreaseLinearCoefficient, .. } -> {
        let timeSinceLendDate = validTo - loanDatum.lendDate
        expect Some(passedHoursSoFarAsRational) =
          rational.new(timeSinceLendDate, 3600000)
        expect Some(apyIncreaseLinearCoefficientAsRational) =
          rational.new(apyIncreaseLinearCoefficient, 1000000)
        expect Some(interestRateAsRational) =
          rational.new(loanDatum.interestRate, 10000)
        expect Some(poolInterestRateAsRational) =
          rational.new(poolDatum.commonData.interestRate, 10000)
        //currenAPY = pyIncreaseLinearCoefficient * passedHoursSoFar + interestRate
        let currentLoanPerpetualAPY =
          rational.add(
            rational.mul(
              apyIncreaseLinearCoefficientAsRational,
              passedHoursSoFarAsRational,
            ),
            interestRateAsRational,
          )
        when
          rational.compare(currentLoanPerpetualAPY, poolInterestRateAsRational)
        is {
          Greater -> True
          Equal -> True
          _ -> False
        }
      }
      _ -> loanDatum.interestRate >= poolDatum.commonData.interestRate
    },
    loanDatum.totalInstallments == poolDatum.commonData.totalInstallments,
    loanDatum.principalAsset == poolDatum.commonData.principalAsset,
    loanDatum.principalOracleAsset == poolDatum.commonData.principalOracleAsset,
    loanDatum.installmentPeriod == poolDatum.commonData.installmentPeriod,
    loanDatum.initialGracePeriod == poolDatum.commonData.initialGracePeriod,
    loanDatum.liquidationMode == poolDatum.commonData.liquidationMode,
    loanDatum.repaymentMode == poolDatum.commonData.repaymentMode,
    loanDatum.repaymentTimeWindow == poolDatum.commonData.repaymentTimeWindow,
    loanDatum.penaltyFeeForLateRepayment == poolDatum.commonData.penaltyFeeForLateRepayment,
    loanDatum.repaymentReceipts == poolDatum.commonData.repaymentReceipts,
    //The pool must support the loan collateral
    poolCollateral == loanDatum.collateral,
    //To have the correct LTV, the collateral in the loan must be >= than the one required by the pool
    loanCollateralAmount >= neededCollateral,
  }
}
