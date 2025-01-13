use cardano/address.{Address}
use cardano/transaction.{OutputReference}
use fluidtokens/types/general.{AuthorizationMethod, CollateralAsset}
use fluidtokens/types/pool.{CommonData}

pub type RequestDatum {
  commonData: CommonData,
  borrowerAuth: AuthorizationMethod,
  borrowerAddress: Address,
  //Same considerations of PoolDatum
  collateral: CollateralAsset,
  //Same considerations of PoolDatum
  principalLTV: Int,
  principalLTVDivider: Int,
  //Same considerations of PoolDatum
  dynamicCollateralPrice: Bool,
  //If true, the output of borrower's bond contains LoanDatum, useful if the borrower is a SC to do onchain validation.
  borrowerTokenOutputMustHaveLoanDatum: Bool,
  //Same considerations of PoolDatum
  permissionedConditionScriptHash: ByteArray,
  //Same considerations of PoolDatum
  extraData: Data,
  //POSIX after which the request is considered expired and anybody can cancel it
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
  CancelAfterExpiration {
    requestId: ByteArray,
    //This output goes back to borrower and contains the collateral minus the lovelace penalty
    borrowerOutputIndex: Int,
  }
  Lend {
    outputWithBorrowerTokenIndex: Int,
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
