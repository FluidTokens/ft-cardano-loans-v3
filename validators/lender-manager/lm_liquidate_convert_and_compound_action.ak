use cardano/address.{Credential}
use cardano/transaction.{Transaction}

validator actionValidator {
  withdraw(_redeemer: Data, _credential: Credential, _self: Transaction) {
    False
  }

  else(_) {
    //We need to be DEX batchers to do this
    fail
  }
}
