var HDWalletProvider = require("@truffle/hdwallet-provider");
const privateKeys = [process.env.WALLET_KEY];

module.exports = {
  networks: {
    // Useful for testing. The `development` name is special - truffle uses it by default
    // if it's defined here and no other network is specified at the command line.
    // You should run a client (like ganache-cli, geth or parity) in a separate terminal
    // tab if you use this network and you must also set the `host`, `port` and `network_id`
    // options below to some value.
    //
    development: {
      host: "127.0.0.1", // Localhost (default: none)
      port: 8545, // Standard Ethereum port (default: none)
      network_id: "*", // Any network (default: none),
      gas: 120000000,
      gasPrice: 1, // To cancel out gasPrice in tests.
    },

    main: {
      provider: () =>
        new HDWalletProvider({
          privateKeys: privateKeys,
          providerOrUrl: `wss://mainnet.infura.io/ws/v3/${process.env.INFURA_PROJECT_ID}`,
          chainId: 1,
        }),
      networkCheckTimeout: 99999999,
      network_id: 1,
    },

    kovan: {
      provider: () =>
        new HDWalletProvider({
          privateKeys: privateKeys,
          providerOrUrl: `wss://kovan.infura.io/ws/v3/${process.env.INFURA_PROJECT_ID}`,
          chainId: 42,
        }),
      networkCheckTimeout: 99999999,
      network_id: 42,
      skipDryRun: true,
      gas: 10000000,
    },
    ropsten: {
      provider: () =>
        new HDWalletProvider({
          privateKeys: privateKeys,
          providerOrUrl: `wss://ropsten.infura.io/ws/v3/${process.env.INFURA_PROJECT_ID}`,
          chainId: 3,
        }),
      networkCheckTimeout: 99999999,
      network_id: 3,
      skipDryRun: true,
      gas: 2900000,
    },
  },
  // Set default mocha options here, use special reporters etc.
  mocha: {
    // timeout: 100000
    reporter: "eth-gas-reporter",
    reporterOptions: { gasPrice: 1, currency: "usd" },
  },

  // Configure your compilers
  compilers: {
    solc: {
      version: ">=0.7 <0.8.0", // Fetch exact version from solc-bin (default: truffle's version)
      docker: false,
      settings: {
        // See the solidity docs for advice about optimization and evmVersion
        optimizer: {
          enabled: true,
          runs: 20000,
        },
        evmVersion: "byzantium",
      },
    },
  },
  plugins: ["truffle-plugin-verify"],
  api_keys: {
    etherscan: process.env.ETHERSCAN,
  },
};
