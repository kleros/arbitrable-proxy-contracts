const AP = artifacts.require("ArbitrableProxy");

const KLEROS = {
  main: "0x988b3a538b618c7a603e1c11ab82cd16dbe28069",
  kovan: "0x60B2AbfDfaD9c0873242f59f2A8c32A3Cc682f80",
  ropsten: "0xab942E7D2bfF0bc5614c968ccc91198fD223C57E",
  sokol: "0xb701ff19fBD9702DD7Ca099Ee7D0D42a2612baB5",
  poa: "0x9C1dA9A04925bDfDedf0f6421bC7EEa8305F9002",
};

module.exports = function (deployer, network) {
  deployer.deploy(AP, KLEROS[network]);
};
