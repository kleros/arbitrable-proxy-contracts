// SPDX-License-Identifier: MIT

/**
 *  @authors: [@ferittuncer]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity ^0.7.6;
import "./IRealitio.sol";

/**
 *  @title IRealitioArbitrator
 *  @dev Based on https://github.com/realitio/realitio-dapp/blob/1860548a51f52eba4930baad051f811e9f7adaee/docs/arbitrators.rst
 */
interface IRealitioArbitrator {
    function realitio() external view returns (IRealitio);

    function metadata() external view returns (string calldata);

    function getDisputeFee(bytes32 questionID) external view returns (uint256);
}
