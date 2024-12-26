use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use cardano/address.{Address, Credential}
use cardano/assets.{flatten, quantity_of}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use fluidtokens/authorizer
use fluidtokens/types/datum.{DutchAuctionDatum}
use fluidtokens/types/general.{Asset}
use fluidtokens/types/redeemer.{DA_Buy, DA_Cancel, DutchAuctionRedeemer}
use fluidtokens/utils.{safe_list_at}
use smart_tokens/utils.{
  get_inputs_from_smart_credential, is_output_to_smart_credential,
} as st_utils

validator dutch_auction(smartTokensSpendScriptHash: ByteArray) {
  withdraw(
    redeemer: DutchAuctionRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    let scInputs =
      get_inputs_from_smart_credential(
        self.inputs,
        credential,
        smartTokensSpendScriptHash,
      )
    //Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
    expect length(scInputs) == length(redeemer.actionsForEachInput)
    expect Finite(validFrom) = self.validity_range.lower_bound.bound_type
    expect Finite(validTo) = self.validity_range.upper_bound.bound_type

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
          DA_Cancel(auth) -> and {
              auth.hash == datum.ownerAuthHash,
              authorizer.authorize_action(auth),
              or {
                validTo < datum.startDate,
                currentPrice <= datum.minPriceToCancel,
              },
            }
          DA_Buy -> {
            expect Some(ownerOutput) = list.at(self.outputs, index)
            if datum.borrowerAddress != None && currentPrice > datum.debtAmount {
              expect Some(borrowerAddress) = datum.borrowerAddress
              //TODO Is the index correct?
              expect Some(borrowerOutput) = list.at(self.outputs, index + 1)
              and {
                correctAmountSentToUser(
                  datum.currency,
                  datum.debtAmount,
                  datum.ownerAddress,
                  ownerOutput,
                  smartTokensSpendScriptHash,
                ),
                correctAmountSentToUser(
                  datum.currency,
                  currentPrice - datum.debtAmount,
                  borrowerAddress,
                  borrowerOutput,
                  smartTokensSpendScriptHash,
                ),
              }
            } else {
              correctAmountSentToUser(
                datum.currency,
                currentPrice,
                datum.ownerAddress,
                ownerOutput,
                smartTokensSpendScriptHash,
              )
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
  currency: Asset,
  amount: Int,
  userAddress: Address,
  userOutput: Output,
  smartTokensSpendScriptHash: ByteArray,
) {
  let correctDestination =
    is_output_to_smart_credential(
      userOutput,
      userAddress.payment_credential,
      userAddress.stake_credential,
      smartTokensSpendScriptHash,
    )

  let correctValue = and {
      quantity_of(userOutput.value, currency.policyId, currency.assetName) >= amount,
      length(flatten(userOutput.value)) <= 21,
    }
  and {
    correctDestination,
    //TODO Datum check?
    correctValue,
  }
}
