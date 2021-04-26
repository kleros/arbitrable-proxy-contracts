// SPDX-License-Identifier: MIT

/**
 *  @authors: [@ferittuncer]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity ^0.7.6;

/**
 *  @title IRealitio
 *  @dev Required subset of https://github.com/realitio/realitio-contracts/blob/master/truffle/contracts/IRealitio.sol to implement a Realitio arbitrator.
 */
interface IRealitio {
    function notifyOfArbitrationRequest(
        bytes32 question_id,
        address requester,
        uint256 max_previous
    ) external;

    function assignWinnerAndSubmitAnswerByArbitrator(
        bytes32 question_id,
        bytes32 answer,
        address payee_if_wrong,
        bytes32 last_history_hash,
        bytes32 last_answer_or_commitment_id,
        address last_answerer
    ) external;
}
