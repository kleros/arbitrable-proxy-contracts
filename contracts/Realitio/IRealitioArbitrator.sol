// SPDX-License-Identifier: MIT

/**
 *  @authors: [@ferittuncer]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

// Based on https://github.com/realitio/realitio-dapp/blob/1860548a51f52eba4930baad051f811e9f7adaee/docs/arbitrators.rst

pragma solidity ^0.7.6;
import "./IRealitio.sol";

interface IRealitioArbitrator {
    function realitio() external view virtual returns (IRealitio);

    function metadata() external view virtual returns (string calldata);
}
