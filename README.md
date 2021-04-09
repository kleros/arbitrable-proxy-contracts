# General Purpose Arbitrable Contracts

General purpose arbitrable contracts as defined in ERC-792

## Testing

```
yarn run ganache
yarn run test
```

## Deployment

To deploy `ArbitrableProxy` run:

```
INFURA_PROJECT_ID=<your_infura_project_id> WALLET_KEY=<your_wallets_private_key> ETHERSCAN=<your_etherscan_api_key> NETWORK=<network_name> yarn deploy
```

This command will also automatically verify the source code on Etherscan.

Note: Network names are defined in `truffle.js`. It has definitions for main, kovan, ropsten and development. Define extra if needed.
