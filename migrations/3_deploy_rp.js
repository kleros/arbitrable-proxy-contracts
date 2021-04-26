const RP = artifacts.require("RealitioProxyWithAppeals");

const metaevidence = "/ipfs/QmR6CczQGwG8kewmvcD1ZYj1oLQ5xBEoqyVYYXWb9CadDo";

module.exports = function (deployer, network) {
  deployer.deploy(
    RP,
    "0x50E35A1ED424aB9C0B8C7095b3d9eC2fb791A168", // Realitio on Kovan,
    "metadata",
    "0x60B2AbfDfaD9c0873242f59f2A8c32A3Cc682f80", // KlerosLiquid on Kovan,
    "0x00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001" // Subcourt 1 - Number of votes 1
  );
};
