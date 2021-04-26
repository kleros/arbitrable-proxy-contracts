var HDWalletProvider = require("@truffle/hdwallet-provider");

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
      provider: () => new HDWalletProvider(process.env.WALLET_KEY, `https://mainnet.infura.io/v3/${process.env.INFURA_PROJECT_ID}`),
      network_id: 1,
      gasPrice: 50000000000, // 50 GWei
      gas: 10000000,
    },

    kovan: {
      provider: () => new HDWalletProvider(process.env.WALLET_KEY, `https://kovan.infura.io/v3/${process.env.INFURA_PROJECT_ID}`),
      network_id: 42,
      skipDryRun: true,
      gas: 10000000,
    },

    ropsten: {
      provider: () => new HDWalletProvider(process.env.WALLET_KEY, `https://ropsten.infura.io/v3/${process.env.INFURA_PROJECT_ID}`),
      network_id: 3,
      skipDryRun: true,
      gas: 8000000,
    },
    // Another network with more advanced options...
    // advanced: {
    // port: 8777,             // Custom port
    // network_id: 1342,       // Custom network
    // gas: 8500000,           // Gas sent with each transaction (default: ~6700000)
    // gasPrice: 20000000000,  // 20 gwei (in wei) (default: 100 gwei)
    // from: <address>,        // Account to send txs from (default: accounts[0])
    // websockets: true        // Enable EventEmitter interface for web3 (default: false)
    // },
    // Useful for deploying to a public network.
    // NB: It's important to wrap the provider as a function.
    // ropsten: {
    // provider: () => new HDWalletProvider(mnemonic, `https://ropsten.infura.io/v3/YOUR-PROJECT-ID`),
    // network_id: 3,       // Ropsten's id
    // gas: 5500000,        // Ropsten has a lower block limit than mainnet
    // confirmations: 2,    // # of confs to wait between deployments. (default: 0)
    // timeoutBlocks: 200,  // # of blocks before a deployment times out  (minimum/default: 50)
    // skipDryRun: true     // Skip dry run before migrations? (default: false for public nets )
    // },
    // Useful for private networks
    // private: {
    // provider: () => new HDWalletProvider(mnemonic, `https://network.io`),
    // network_id: 2111,   // This network is yours, in the cloud.
    // production: true    // Treats this network as if it was a public net. (default: false)
    // }
  },
  // Set default mocha options here, use special reporters etc.
  mocha: {
    // timeout: 100000
    // reporter: "eth-gas-reporter",
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
