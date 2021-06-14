const AP = artifacts.require("ArbitrableProxy");

const KLEROS = {
  main: "0x988b3a538b618c7a603e1c11ab82cd16dbe28069",
  kovan: "0x60B2AbfDfaD9c0873242f59f2A8c32A3Cc682f80",
  ropsten: "0xab942E7D2bfF0bc5614c968ccc91198fD223C57E",
  sokol: "0xec8726b782D77fC9Fdf64d12D895CA15956b9e0e",
};

module.exports = function (deployer, network) {
  deployer.deploy(AP, KLEROS[network]);
};
