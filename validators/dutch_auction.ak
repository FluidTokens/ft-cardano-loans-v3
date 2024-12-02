use aiken/collection/list.{length}
use aiken/interval.{Finite, Interval}
use cardano/address.{Address, Credential, PaymentCredential, Script}
use cardano/assets.{flatten, quantity_of}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use types/datum.{DutchAuctionDatum}
use types/general.{Asset}
use types/redeemer.{DA_Buy, DA_Cancel, DutchAuctionRedeemer}
use utils.{get_inputs_from_sc_or_delegated_to_sc, safe_list_at}

validator dutch_auction {
  withdraw(
    redeemer: DutchAuctionRedeemer,
    credential: Credential,
    self: Transaction,
  ) {
    expect Script(ownScriptHash) = credential
    let scInputs =
      get_inputs_from_sc_or_delegated_to_sc(self.inputs, ownScriptHash)
    //Number of actions must be equal to the sc inputs, otherwise some inputs won't be checked
    expect length(scInputs) == length(redeemer.actionForEachInput)
    expect Finite(validTo) = self.validity_range.upper_bound.bound_type

    list.indexed_foldr(
      scInputs,
      True,
      fn(index, inputAndCIP113Control, result) {
        //As all inputs must return True, if any of previous input returned False, then fail
        //The last input is not checked but will return its value at the end, so if False withdraw will fail
        expect result

        let input = inputAndCIP113Control.1st
        let isCIP113 = inputAndCIP113Control.2nd
        expect InlineDatum(inputDatum) = input.output.datum
        expect datum: DutchAuctionDatum = inputDatum
        let redeemerAction = safe_list_at(redeemer.actionForEachInput, index)
        let currentPrice =
          get_current_price(
            datum.startingPrice,
            datum.loweringAmount,
            datum.loweringFrequency,
            datum.startDate,
            validTo,
          )

        when redeemerAction is {
          DA_Cancel -> or {
              validTo < datum.startDate,
              currentPrice <= datum.minPriceToCancel,
            }
          DA_Buy -> {
            expect Some(ownerOutput) = list.at(self.outputs, index)
            if
            datum.borrowerAddress != None && currentPrice > datum.debtAmount{
            
              expect Some(borrowerAddress) = datum.borrowerAddress
              //TODO Is the index correct?
              expect Some(borrowerOutput) = list.at(self.outputs, index + 1)
              and {
                correctAmountSentToUser(
                  datum.currency,
                  datum.debtAmount,
                  datum.ownerAddress,
                  ownerOutput,
                  isCIP113,
                  input.output.address.payment_credential,
                ),
                correctAmountSentToUser(
                  datum.currency,
                  currentPrice - datum.debtAmount,
                  borrowerAddress,
                  borrowerOutput,
                  isCIP113,
                  input.output.address.payment_credential,
                ),
              }
            } else {
              correctAmountSentToUser(
                datum.currency,
                currentPrice,
                datum.ownerAddress,
                ownerOutput,
                isCIP113,
                input.output.address.payment_credential,
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
  isCIP113: Bool,
  prevPaymentCredential: PaymentCredential,
) {
  let toCorrectPaymentCredential =
    if isCIP113 {
      userOutput.address.payment_credential == prevPaymentCredential
    } else {
      userOutput.address.payment_credential == userAddress.payment_credential
    }
  let toCorrectStaking =
    userOutput.address.stake_credential == userAddress.stake_credential

  let correctValue = and {
      quantity_of(userOutput.value, currency.policyId, currency.assetName) >= amount,
      length(flatten(userOutput.value)) <= 21,
    }
  and {
    toCorrectPaymentCredential,
    toCorrectStaking,
    correctValue,
  }
}
