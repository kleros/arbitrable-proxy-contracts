const BAP = artifacts.require("ArbitrableProxy");

module.exports = function(deployer, network) {
  if (network == "main")
    deployer.deploy(
      BAP,
      "0x988b3a538b618c7a603e1c11ab82cd16dbe28069", // KlerosLiquid on Main
      "10000",
      "20000",
      "10000"
    );
  else if (network == "kovan")
    deployer.deploy(
      BAP,
      "0x60B2AbfDfaD9c0873242f59f2A8c32A3Cc682f80", // KlerosLiquid on Kovan
      "10000",
      "20000",
      "10000"
    );
};
