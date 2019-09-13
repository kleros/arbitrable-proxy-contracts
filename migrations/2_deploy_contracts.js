const BinaryArbitrableProxy = artifacts.require('./BinaryArbitrableProxy.sol')

module.exports = function(deployer, network, accounts) {
  deployer.deploy(BinaryArbitrableProxy, 1, 1, 1)
}
