const BinaryArbitrableProxy = artifacts.require('./BinaryArbitrableProxy.sol')

module.exports = function(deployer) {
  deployer.deploy(BinaryArbitrableProxy)
}
