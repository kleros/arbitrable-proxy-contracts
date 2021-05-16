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

ArbitrableProxy live at [Main](https://etherscan.io/address/0xA3B02bA6E10F55fb177637917B1b472da0110CcC), [Ropsten](0x296bdb4c324A9445167872Da2dD0Fa328b6D3520) and [Kovan](0x334841678CBF81f447E70A40f552b041A15D27f6).
BinaryArbitrableProxy is no longer used.
