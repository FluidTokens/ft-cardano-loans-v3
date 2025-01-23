# FluidTokens Lending V5

This repo contains the official smart contracts for the latest lending platform of FluidTokens.
The logic is thought to be highly customizable, as the same contracts may be used for different flavours of lending.

## Features

The following features are supported:
* Static lending pools: owned by a single user (can be wallet or script) and can be spent by multiple borrowers until they are emptied
* Dynamic lending pools: like static pools but the borrowable amount is enstablished by LTV and oracles
* In the same tx, the borrower can borrow from multiple pools
* Static and dynamic loan requests: borrower can request a specific loan that lenders can accept
* Each pool can accept different collaterals but only 1 for each loan
* Installments: split the repayment of the loan in multiple installments
* Initial grace period where borrower doesn't have to repay yet
* Penalty fee for late repayments
* 4 liquidation types:
    * No liquidation, lender gets all the collateral if borrower doesn't repay in time
    * No liquidation, collateral goes to a dutch auction that can potentially repay the difference to the borrower
    * Oracle liquidation, lender gets all the collateral
    * Oracle liquidation, lender gets the collateral but has to pay the borrower the difference
* 2 repayment formulas:
    * (Principal+Interest)/Installments
    * Amortization formula
* Generation of bonds for lender and borrower in order to be flexible with their position
* Lender bond can have datum to be compatible with PlutusV2 scripts
* Recast: in case the Amortization formula is used, borrower can repay a number of times the principal to reduce the debt
* Refinancing: repayng in one tx the loan with the liquidity coming from a new loan
* Permissioned pools and loan requests:
    * The pool is spendable if a KYC token is properly added to the tx
    * The request can be accepted if the lender is a specific user (wallet or script)
* Pools, requests, loans and repayments utxos are identified by a unique NFT to allow on-chain accounting (no fake pools, etc.)
* 3 types of oracle feeds (they are always tokenX/lovelace):
    * Aggregated: from CEX
    * Pooled: from DEX
    * Dedicated: dedicated for specific use cases (where the value of the collateral must come from outside sources)
* CIP113 (smart tokens) support: principal, collateral and oracle feed support CIP113 tokens
* Custom field to explain what a particular repayment is referring to

## Scripts

The most important scripts contained are the following:
* config.ak: global configuration of the whole protocol, upgradable
* general_spend.ak: a general spend validator that delegates to a specific withdraw validator (we always use the Withdraw 0 trick)
* oracle.ak: uses the withdraw validator to allow a set of signers to confirm the oracle value
* authorizer.ak: manage authorization of different ways (signature, withdraw, mint, etc.) 
* pool.ak: lender pools
* request.ak: borrower requests
* loan.ak: active loan (in progress)
* repayment.ak: all types of repayments (installments, partial liquidations, recasts, etc.)
* dutch_auction.ak: dutch auction where the price gradually decreases until someone buys it