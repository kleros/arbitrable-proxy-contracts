const AP = artifacts.require("ArbitrableProxy");

module.exports = function (deployer, network) {
  if (network == "main")
    deployer.deploy(
      AP,
      "0x988b3a538b618c7a603e1c11ab82cd16dbe28069" // KlerosLiquid on Main
    );
  else if (network == "kovan")
    deployer.deploy(
      AP,
      "0x60B2AbfDfaD9c0873242f59f2A8c32A3Cc682f80" // KlerosLiquid on Kovan
    );
  else if (network == "ropsten")
    deployer.deploy(
      AP,
      "0xab942E7D2bfF0bc5614c968ccc91198fD223C57E" // KlerosLiquid on Ropsten
    );
};
