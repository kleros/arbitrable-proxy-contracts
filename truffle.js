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
      networkCheckTimeout: 999999,
      network_id: 1,
      gasPrice: 80000000000, // 80 gwei
      gas: 4000000,
    },

    sepolia: {
      provider: function() {
        return new HDWalletProvider({
          privateKeys: privateKeys,
          providerOrUrl: `https://sepolia.infura.io/v3/${process.env.INFURA_PROJECT_ID}`,
          chainId: 11155111,
        });
      },
      networkCheckTimeout: 99999999,
      network_id: 11155111,
      skipDryRun: true,
    },
    sokol: {
      provider: () =>
        new HDWalletProvider({
          privateKeys: privateKeys,
          providerOrUrl: "https://sokol.poa.network",
          chainId: 77,
        }),
      network_id: 77,
      skipDryRun: true,
      networkCheckTimeout: 99999999,
      gas: 5000000,
      gasPrice: 1000000000,
    },
    xdai: {
      provider: () =>
        new HDWalletProvider({
          privateKeys: privateKeys,
          providerOrUrl: "https://rpc.xdaichain.com",
          chainId: 100,
        }),
      network_id: 100,
      networkCheckTimeout: 2000000,
      gas: 5000000,
      gasPrice: 20000000000, // 20 gwei
    },



    polygon: {
      provider: () =>
        new HDWalletProvider({
          privateKeys: privateKeys,
          providerOrUrl: "https://matic-mainnet.chainstacklabs.com",
          chainId: 137,
        }),
      network_id: 137,
      networkCheckTimeout: 2000000,
      gas: 5000000,
      gasPrice: 20000000000, // 20 gwei
    },

    mumbai: {
      provider: () =>
        new HDWalletProvider({
          privateKeys: privateKeys,
          providerOrUrl: "https://polygon-mumbai.g.alchemy.com/v2/PX_3q-P-AbxWKn8qiTvF5A6TFSMfQ4jz",
          chainId: 80001,
        }),
      network_id: 80001,
      networkCheckTimeout: 2000000,
      gas: 5000000,
      gasPrice: 20000000000, // 20 gwei
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
  etherscan: {
    apiKey: process.env.ETHERSCAN
  }
};
