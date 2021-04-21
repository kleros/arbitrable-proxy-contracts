// SPDX-License-Identifier: MIT

/**
 *  @authors: [@ferittuncer]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

// Copied by @ferittuncer from https://github.com/realitio/realitio-contracts/blob/master/truffle/contracts/IRealitio.sol to adapt to solc 0.7.x. Original author is https://github.com/edmundedgar.

pragma solidity ^0.7.6;
pragma abicoder v2;

abstract contract IRealitio {
    address constant NULL_ADDRESS = address(0);

    // History hash when no history is created, or history has been cleared
    bytes32 constant NULL_HASH = bytes32(0);

    // An unitinalized finalize_ts for a question will indicate an unanswered question.
    uint32 constant UNANSWERED = 0;

    // An unanswered reveal_ts for a commitment will indicate that it does not exist.
    uint256 constant COMMITMENT_NON_EXISTENT = 0;

    // Commit->reveal timeout is 1/8 of the question timeout (rounded down).
    uint32 constant COMMITMENT_TIMEOUT_RATIO = 8;

    // Proportion withheld when you claim an earlier bond.
    uint256 constant BOND_CLAIM_FEE_PROPORTION = 40; // One 40th ie 2.5%

    struct Question {
        bytes32 content_hash;
        address arbitrator;
        uint32 opening_ts;
        uint32 timeout;
        uint32 finalize_ts;
        bool is_pending_arbitration;
        uint256 bounty;
        bytes32 best_answer;
        bytes32 history_hash;
        uint256 bond;
    }

    // Stored in a mapping indexed by commitment_id, a hash of commitment hash, question, bond.
    struct Commitment {
        uint32 reveal_ts;
        bool is_revealed;
        bytes32 revealed_answer;
    }

    // Only used when claiming more bonds than fits into a transaction
    // Stored in a mapping indexed by question_id.
    struct Claim {
        address payee;
        uint256 last_bond;
        uint256 queued_funds;
    }

    event LogSetQuestionFee(address arbitrator, uint256 amount);

    event LogNewTemplate(uint256 indexed template_id, address indexed user, string question_text);

    event LogNewQuestion(bytes32 indexed question_id, address indexed user, uint256 template_id, string question, bytes32 indexed content_hash, address arbitrator, uint32 timeout, uint32 opening_ts, uint256 nonce, uint256 created);

    event LogFundAnswerBounty(bytes32 indexed question_id, uint256 bounty_added, uint256 bounty, address indexed user);

    event LogNewAnswer(bytes32 answer, bytes32 indexed question_id, bytes32 history_hash, address indexed user, uint256 bond, uint256 ts, bool is_commitment);

    event LogAnswerReveal(bytes32 indexed question_id, address indexed user, bytes32 indexed answer_hash, bytes32 answer, uint256 nonce, uint256 bond);

    event LogNotifyOfArbitrationRequest(bytes32 indexed question_id, address indexed user);

    event LogCancelArbitration(bytes32 indexed question_id);

    event LogFinalize(bytes32 indexed question_id, bytes32 indexed answer);

    event LogClaim(bytes32 indexed question_id, address indexed user, uint256 amount);

    event LogWithdraw(address indexed user, uint256 amount);

    function claimWinnings(
        bytes32 question_id,
        bytes32[] calldata history_hashes,
        address[] calldata addrs,
        uint256[] calldata bonds,
        bytes32[] calldata answers
    ) external virtual;

    function getFinalAnswerIfMatches(
        bytes32 question_id,
        bytes32 content_hash,
        address arbitrator,
        uint32 min_timeout,
        uint256 min_bond
    ) external view virtual returns (bytes32);

    function getBounty(bytes32 question_id) external view virtual returns (uint256);

    function getArbitrator(bytes32 question_id) external view virtual returns (address);

    function getBond(bytes32 question_id) external view virtual returns (uint256);

    // Disabled because of stack too deep error.
    // function claimMultipleAndWithdrawBalance(
    //     bytes32[] calldata question_ids,
    //     uint256[] calldata lengths,
    //     bytes32[] calldata hist_hashes,
    //     address[] calldata addrs,
    //     uint256[] calldata bonds,
    //     bytes32[] calldata answers
    // ) external virtual;

    function withdraw() public virtual;

    function submitAnswerReveal(
        bytes32 question_id,
        bytes32 answer,
        uint256 nonce,
        uint256 bond
    ) external virtual;

    function setQuestionFee(uint256 fee) external virtual;

    function template_hashes(uint256) public view virtual returns (bytes32);

    function getContentHash(bytes32 question_id) external view virtual returns (bytes32);

    function question_claims(bytes32) external view virtual returns (Claim memory);

    function fundAnswerBounty(bytes32 question_id) external payable virtual;

    function arbitrator_question_fees(address) external view virtual returns (uint256);

    function balanceOf(address) public view virtual returns (uint256);

    function askQuestion(
        uint256 template_id,
        string calldata question,
        address arbitrator,
        uint32 timeout,
        uint32 opening_ts,
        uint256 nonce
    ) external payable virtual returns (bytes32);

    function submitAnswer(
        bytes32 question_id,
        bytes32 answer,
        uint256 max_previous
    ) external payable virtual;

    function submitAnswerFor(
        bytes32 question_id,
        bytes32 answer,
        uint256 max_previous,
        address answerer
    ) external payable virtual;

    function isFinalized(bytes32 question_id) public view virtual returns (bool);

    function getHistoryHash(bytes32 question_id) external view virtual returns (bytes32);

    function commitments(bytes32) public view virtual returns (Commitment memory);

    function createTemplate(string calldata content) external virtual returns (uint256);

    function getBestAnswer(bytes32 question_id) external view virtual returns (bytes32);

    function isPendingArbitration(bytes32 question_id) external view virtual returns (bool);

    function questions(bytes32) public view virtual returns (Question memory);

    function getOpeningTS(bytes32 question_id) external view virtual returns (uint32);

    function getTimeout(bytes32 question_id) external view virtual returns (uint32);

    function createTemplateAndAskQuestion(
        string calldata content,
        string calldata question,
        address arbitrator,
        uint32 timeout,
        uint32 opening_ts,
        uint256 nonce
    ) external payable virtual returns (bytes32);

    function getFinalAnswer(bytes32 question_id) external view virtual returns (bytes32);

    function getFinalizeTS(bytes32 question_id) external view virtual returns (uint32);

    function templates(uint256) public view virtual returns (uint256);

    function resultFor(bytes32 question_id) external view virtual returns (bytes32);

    function submitAnswerCommitment(
        bytes32 question_id,
        bytes32 answer_hash,
        uint256 max_previous,
        address _answerer
    ) external payable virtual;

    function notifyOfArbitrationRequest(
        bytes32 question_id,
        address requester,
        uint256 max_previous
    ) external virtual;

    function submitAnswerByArbitrator(
        bytes32 question_id,
        bytes32 answer,
        address answerer
    ) external virtual;

    function assignWinnerAndSubmitAnswerByArbitrator(
        bytes32 question_id,
        bytes32 answer,
        address payee_if_wrong,
        bytes32 last_history_hash,
        bytes32 last_answer_or_commitment_id,
        address last_answerer
    ) external virtual;

    function cancelArbitration(bytes32 question_id) external virtual; // Only available from v2.1
}
