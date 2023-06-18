const AP = artifacts.require("ArbitrableProxy");

const KLEROS = {
  main: "0x988b3a538b618c7a603e1c11ab82cd16dbe28069",
  ropsten: "0xab942E7D2bfF0bc5614c968ccc91198fD223C57E",
  rinkeby: "0x6e376E049BD375b53d31AFDc21415AeD360C1E70",
  görli: "0x1128eD55ab2d796fa92D2F8E1f336d745354a77A",
  kovan: "0x60B2AbfDfaD9c0873242f59f2A8c32A3Cc682f80",
  sokol: "0xb701ff19fBD9702DD7Ca099Ee7D0D42a2612baB5",
  xdai: "0x9C1dA9A04925bDfDedf0f6421bC7EEa8305F9002",
  sepolia: "0x90992fb4E15ce0C59aEFfb376460Fda4Ee19C879"
};

module.exports = function (deployer, network) {
  deployer.deploy(AP, KLEROS[network]);
};
