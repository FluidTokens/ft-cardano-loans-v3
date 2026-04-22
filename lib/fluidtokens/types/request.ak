use cardano/address.{Address}
use cardano/transaction.{OutputReference}
use fluidtokens/types/general.{AuthorizationMethod, CollateralAsset}
use fluidtokens/types/pool.{CommonData}

pub type RequestDatum {
  //Same considerations of PoolDatum
  permissionedLendConditionScriptHash: ByteArray,
  //Extend the pool datum for cases like permissioned pools. 
  //It will be parsed properly depending on specific use case.
  //1st is data for permissioned lend
  //2nd is data for permissioned debt transfer
  //3rd is data for permissioned liquidation
  extraData: List<Data>,
  commonData: CommonData,
  borrowerAuth: AuthorizationMethod,
  borrowerAddress: Address,
  //Same considerations of PoolDatum
  collateral: CollateralAsset,
  //Same considerations of PoolDatum minCollateral
  minPrincipal: Int,
  minPrincipalDivider: Int,
  //Max principal that the borrower can accept, to avoid an immediate liquidation by a malicious lender that gives too much
  maxPrincipal: Int,
  //Same considerations of PoolDatum
  dynamicCollateralPrice: Bool,
  //POSIX millis after which the request is considered expired and anybody can cancel it
  requestExpiration: Int,
  //In lovelace, how much you earn removing this expired request from the smart contract
  requestExpirationPenalty: Int,
}

pub type RequestMintRedeemer {
  configRefInputIndex: Int,
  inputRef: OutputReference,
}

pub type RequestAction {
  Cancel { requestId: ByteArray }
  CancelAfterExpiration { requestId: ByteArray }
  Lend {
    //Ref input index of the principal oracle, if principal is ADA this must be -1
    principalOracleRefInputIndex: Int,
    //If collateral doesn't use oracle or is ADA, this must be -1
    collateralOracleRefInputIndex: Int,
    givenPrincipalAmount: Int,
    requestId: ByteArray,
    permissionedConditionWithdrawIndex: Int,
  }
}

pub type RequestWithdrawRedeemer {
  configRefInputIndex: Int,
  actionsForEachInput: List<RequestAction>,
}
