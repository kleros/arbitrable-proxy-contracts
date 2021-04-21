// SPDX-License-Identifier: MIT

/**
 *  @authors: [@ferittuncer]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

// Copied by @ferittuncer from https://github.com/realitio/realitio-contracts/blob/master/truffle/contracts/RealitioSafeMath32.sol to adapt to solc 0.7.x. Original author is https://github.com/edmundedgar.

pragma solidity ^0.7.6;

/**
 * @title RealitioSafeMath32
 * @dev Math operations with safety checks that throw on error
 * @dev Copy of SafeMath but for uint32 instead of uint256
 * @dev Deleted functions we don't use
 */
library RealitioSafeMath32 {
    function add(uint32 a, uint32 b) internal pure returns (uint32) {
        uint32 c = a + b;
        assert(c >= a);
        return c;
    }
}
