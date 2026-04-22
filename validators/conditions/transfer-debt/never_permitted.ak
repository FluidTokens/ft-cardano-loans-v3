use cardano/address.{Credential}
use cardano/transaction.{Transaction}

validator never_permitted {
  withdraw(_redeemer: Data, _credential: Credential, _self: Transaction) {
    False
  }

  else(_) {
    fail
  }
}
