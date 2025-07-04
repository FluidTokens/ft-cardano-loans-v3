use aiken/builtin
use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use cardano/address.{Address, Credential, Script}
use cardano/assets.{flatten, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use fluidtokens/authorizer
use fluidtokens/types/dutch_auction.{
  Buy, Cancel, DutchAuctionDatum, DutchAuctionRedeemer,
} as da
use fluidtokens/types/general.{Asset}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, is_output_to_user_smart_credential,
} as st_utils

validator dutch_auction(
  configNFTPolicyId: ByteArray,
  configNFTAssetName: ByteArray,
) {
  withdraw(
    redeemer: DutchAuctionRedeemer,
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
    let dutchAuctionSpendScriptHash =
      builtin.un_b_data(utils.safe_list_at(config, 16))
    let scInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        Script(dutchAuctionSpendScriptHash),
        credential,
        smartTokensSpendScriptHash,
      )
    //Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
    expect length(scInputs) == length(redeemer.actionsForEachInput)
    expect (Finite(validFrom), Finite(validTo)) =
      (
        self.validity_range.lower_bound.bound_type,
        self.validity_range.upper_bound.bound_type,
      )

    list.indexed_foldr(
      scInputs,
      True,
      fn(index, input, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: DutchAuctionDatum = inputDatum
        let redeemerAction = safe_list_at(redeemer.actionsForEachInput, index)
        let currentPrice =
          get_current_price(
            datum.startingPrice,
            datum.loweringAmount,
            datum.loweringFrequency,
            datum.startDate,
            validFrom,
          )

        when redeemerAction is {
          Cancel -> and {
              authorizer.authorize_action(
                authorizer.create_auth(
                  datum.ownerAuth,
                  self.inputs,
                  self.withdrawals,
                  self.extra_signatories,
                  self.mint,
                ),
              ),
              or {
                and {
                  datum.borrowerAddress == None,
                  validTo < datum.startDate,
                },
                currentPrice <= datum.minPriceToCancel,
              },
            }
          Buy -> {
            let ownerOutput = utils.safe_list_at(self.outputs, index * 2)
            and {
              datum.startDate <= validFrom,
              if datum.borrowerAddress != None && currentPrice > datum.debtAmount {
                expect Some(borrowerAddress) = datum.borrowerAddress
                let borrowerOutput =
                  utils.safe_list_at(self.outputs, index * 2 + 1)
                and {
                  correctAmountSentToUser(
                    input.output_reference,
                    datum.currency,
                    datum.debtAmount,
                    datum.ownerAddress,
                    ownerOutput,
                    smartTokensSpendScriptHash,
                  ),
                  correctAmountSentToUser(
                    input.output_reference,
                    datum.currency,
                    currentPrice - datum.debtAmount,
                    borrowerAddress,
                    borrowerOutput,
                    smartTokensSpendScriptHash,
                  ),
                }
              } else {
                correctAmountSentToUser(
                  input.output_reference,
                  datum.currency,
                  currentPrice,
                  datum.ownerAddress,
                  ownerOutput,
                  smartTokensSpendScriptHash,
                )
              },
            }
          }
        }
      },
    )
  }

  else(_) {
    fail
  }
}

fn get_current_price(
  startingPrice: Int,
  loweringAmount: Int,
  loweringFrequency: Int,
  startDate: Int,
  now: Int,
) {
  startingPrice - ( now - startDate ) / loweringFrequency * loweringAmount
}

fn correctAmountSentToUser(
  auctionRef: OutputReference,
  currency: Asset,
  amount: Int,
  userAddress: Address,
  userOutput: Output,
  smartTokensSpendScriptHash: ByteArray,
) {
  let correctDestination =
    is_output_to_user_smart_credential(
      userOutput,
      userAddress.payment_credential,
      userAddress.stake_credential,
      smartTokensSpendScriptHash,
    )

  let crossScriptDoubleSpendProtectionDatum =
    userOutput.datum == InlineDatum(auctionRef)

  let correctValue = and {
      quantity_of(userOutput.value, currency.policyId, currency.assetName) >= amount,
      if currency.policyId == "" {
        length(flatten(userOutput.value)) == 1
      } else {
        length(flatten(userOutput.value)) == 2
      },
    }
  and {
    correctDestination,
    crossScriptDoubleSpendProtectionDatum,
    correctValue,
  }
}
