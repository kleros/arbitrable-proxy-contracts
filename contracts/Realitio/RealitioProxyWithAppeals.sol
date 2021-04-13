// SPDX-License-Identifier: MIT

/**
 *  @authors: [@ferittuncer]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity >=0.7;
pragma abicoder v2;

import "./IRealitio.sol";
import "./RealitioSafeMath32.sol";
import "./RealitioSafeMath256.sol";
import "../IDisputeResolver.sol";

contract RealitioProxyWithAppeals is IRealitio {
    IRealitio public realitiov2;

    using RealitioSafeMath256 for uint256;
    using RealitioSafeMath32 for uint32;

    uint256 nextTemplateID = 0;

    /// @notice Constructor, sets up some initial templates
    /// @dev Creates some generalized templates for different question types used in the DApp.
    constructor(IRealitio _realitiov2) {
        realitiov2 = _realitiov2;
    }

    /// @notice Function for arbitrator to set an optional per-question fee.
    /// @dev The per-question fee, charged when a question is asked, is intended as an anti-spam measure.
    /// @param fee The fee to be charged by the arbitrator when a question is asked
    function setQuestionFee(uint256 fee) external override {
        return realitiov2.setQuestionFee(fee);
    }

    /// @notice Create a reusable template, which should be a JSON document.
    /// Placeholders should use gettext() syntax, eg %s.
    /// @dev Template data is only stored in the event logs, but its block number is kept in contract storage.
    /// @param content The template content
    /// @return The ID of the newly-created template, which is created sequentially.
    function createTemplate(string calldata content) public override returns (uint256) {
        return realitiov2.createTemplate(content);
    }

    /// @notice Create a new reusable template and use it to ask a question
    /// @dev Template data is only stored in the event logs, but its block number is kept in contract storage.
    /// @param content The template content
    /// @param question A string containing the parameters that will be passed into the template to make the question
    /// @param arbitrator The arbitration contract that will have the final word on the answer if there is a dispute
    /// @param timeout How long the contract should wait after the answer is changed before finalizing on that answer
    /// @param opening_ts If set, the earliest time it should be possible to answer the question.
    /// @param nonce A user-specified nonce used in the question ID. Change it to repeat a question.
    /// @return The ID of the newly-created template, which is created sequentially.
    function createTemplateAndAskQuestion(
        string calldata content,
        string calldata question,
        address arbitrator,
        uint32 timeout,
        uint32 opening_ts,
        uint256 nonce
    ) public payable override returns (bytes32) {
        uint256 template_id = createTemplate(content);
        return askQuestion(template_id, question, arbitrator, timeout, opening_ts, nonce);
    }

    /// @notice Ask a new question and return the ID
    /// @dev Template data is only stored in the event logs, but its block number is kept in contract storage.
    /// @param template_id The ID number of the template the question will use
    /// @param question A string containing the parameters that will be passed into the template to make the question
    /// @param arbitrator The arbitration contract that will have the final word on the answer if there is a dispute
    /// @param timeout How long the contract should wait after the answer is changed before finalizing on that answer
    /// @param opening_ts If set, the earliest time it should be possible to answer the question.
    /// @param nonce A user-specified nonce used in the question ID. Change it to repeat a question.
    /// @return The ID of the newly-created question, created deterministically.
    function askQuestion(
        uint256 template_id,
        string calldata question,
        address arbitrator,
        uint32 timeout,
        uint32 opening_ts,
        uint256 nonce
    ) public payable override returns (bytes32) {
        return realitiov2.askQuestion(template_id, question, arbitrator, timeout, opening_ts, nonce);
    }

    /// @notice Add funds to the bounty for a question
    /// @dev Add bounty funds after the initial question creation. Can be done any time until the question is finalized.
    /// @param question_id The ID of the question you wish to fund
    function fundAnswerBounty(bytes32 question_id) external payable override {
        return realitiov2.fundAnswerBounty(question_id);
    }

    /// @notice Submit an answer for a question.
    /// @dev Adds the answer to the history and updates the current "best" answer.
    /// May be subject to front-running attacks; Substitute submitAnswerCommitment()->submitAnswerReveal() to prevent them.
    /// @param question_id The ID of the question
    /// @param answer The answer, encoded into bytes32
    /// @param max_previous If specified, reverts if a bond higher than this was submitted after you sent your transaction.
    function submitAnswer(
        bytes32 question_id,
        bytes32 answer,
        uint256 max_previous
    ) external payable override {
        return realitiov2.submitAnswer(question_id, answer, max_previous);
    }

    /// @notice Submit an answer for a question, crediting it to the specified account.
    /// @dev Adds the answer to the history and updates the current "best" answer.
    /// May be subject to front-running attacks; Substitute submitAnswerCommitment()->submitAnswerReveal() to prevent them.
    /// @param question_id The ID of the question
    /// @param answer The answer, encoded into bytes32
    /// @param max_previous If specified, reverts if a bond higher than this was submitted after you sent your transaction.
    /// @param answerer The account to which the answer should be credited
    function submitAnswerFor(
        bytes32 question_id,
        bytes32 answer,
        uint256 max_previous,
        address answerer
    ) external payable override {
        return realitiov2.submitAnswerFor(question_id, answer, max_previous, answerer);
    }

    /// @notice Submit the hash of an answer, laying your claim to that answer if you reveal it in a subsequent transaction.
    /// @dev Creates a hash, commitment_id, uniquely identifying this answer, to this question, with this bond.
    /// The commitment_id is stored in the answer history where the answer would normally go.
    /// Does not update the current best answer - this is left to the later submitAnswerReveal() transaction.
    /// @param question_id The ID of the question
    /// @param answer_hash The hash of your answer, plus a nonce that you will later reveal
    /// @param max_previous If specified, reverts if a bond higher than this was submitted after you sent your transaction.
    /// @param _answerer If specified, the address to be given as the question answerer. Defaults to the sender.
    /// @dev Specifying the answerer is useful if you want to delegate the commit-and-reveal to a third-party.
    function submitAnswerCommitment(
        bytes32 question_id,
        bytes32 answer_hash,
        uint256 max_previous,
        address _answerer
    ) external payable override {
        realitiov2.submitAnswerCommitment(question_id, answer_hash, max_previous, _answerer);
    }

    /// @notice Submit the answer whose hash you sent in a previous submitAnswerCommitment() transaction
    /// @dev Checks the parameters supplied recreate an existing commitment, and stores the revealed answer
    /// Updates the current answer unless someone has since supplied a new answer with a higher bond
    /// msg.sender is intentionally not restricted to the user who originally sent the commitment;
    /// For example, the user may want to provide the answer+nonce to a third-party service and let them send the tx
    /// NB If we are pending arbitration, it will be up to the arbitrator to wait and see any outstanding reveal is sent
    /// @param question_id The ID of the question
    /// @param answer The answer, encoded as bytes32
    /// @param nonce The nonce that, combined with the answer, recreates the answer_hash you gave in submitAnswerCommitment()
    /// @param bond The bond that you paid in your submitAnswerCommitment() transaction
    function submitAnswerReveal(
        bytes32 question_id,
        bytes32 answer,
        uint256 nonce,
        uint256 bond
    ) external override {
        return realitiov2.submitAnswerReveal(question_id, answer, nonce, bond);
    }

    /// @notice Notify the contract that the arbitrator has been paid for a question, freezing it pending their decision.
    /// @dev The arbitrator contract is trusted to only call this if they've been paid, and tell us who paid them.
    /// @param question_id The ID of the question
    /// @param requester The account that requested arbitration
    /// @param max_previous If specified, reverts if a bond higher than this was submitted after you sent your transaction.
    function notifyOfArbitrationRequest(
        bytes32 question_id,
        address requester,
        uint256 max_previous
    ) external override {
        return;
    }

    /// @notice Cancel a previously-requested arbitration and extend the timeout
    /// @dev Useful when doing arbitration across chains that can't be requested atomically
    /// @param question_id The ID of the question
    function cancelArbitration(bytes32 question_id) external override {
        revert("Unsupported operation.");
    }

    /// @notice Submit the answer for a question, for use by the arbitrator.
    /// @dev Doesn't require (or allow) a bond.
    /// If the current final answer is correct, the account should be whoever submitted it.
    /// If the current final answer is wrong, the account should be whoever paid for arbitration.
    /// However, the answerer stipulations are not enforced by the contract.
    /// @param question_id The ID of the question
    /// @param answer The answer, encoded into bytes32
    /// @param answerer The account credited with this answer for the purpose of bond claims
    function submitAnswerByArbitrator(
        bytes32 question_id,
        bytes32 answer,
        address answerer
    ) public override {
        return;
    }

    /// @notice Submit the answer for a question, for use by the arbitrator, working out the appropriate winner based on the last answer details.
    /// @dev Doesn't require (or allow) a bond.
    /// @param question_id The ID of the question
    /// @param answer The answer, encoded into bytes32
    /// @param payee_if_wrong The account to by credited as winner if the last answer given is wrong, usually the account that paid the arbitrator
    /// @param last_history_hash The history hash before the final one
    /// @param last_answer_or_commitment_id The last answer given, or the commitment ID if it was a commitment.
    /// @param last_answerer The address that supplied the last answer
    function assignWinnerAndSubmitAnswerByArbitrator(
        bytes32 question_id,
        bytes32 answer,
        address payee_if_wrong,
        bytes32 last_history_hash,
        bytes32 last_answer_or_commitment_id,
        address last_answerer
    ) external override {
        return;
    }

    /// @notice Report whether the answer to the specified question is finalized
    /// @param question_id The ID of the question
    /// @return Return true if finalized
    function isFinalized(bytes32 question_id) public view override returns (bool) {
        return realitiov2.isFinalized(question_id);
    }

    /// @notice (Deprecated) Return the final answer to the specified question, or revert if there isn't one
    /// @param question_id The ID of the question
    /// @return The answer formatted as a bytes32
    function getFinalAnswer(bytes32 question_id) external view override returns (bytes32) {
        return realitiov2.getFinalAnswer(question_id);
    }

    /// @notice Return the final answer to the specified question, or revert if there isn't one
    /// @param question_id The ID of the question
    /// @return The answer formatted as a bytes32
    function resultFor(bytes32 question_id) external view override returns (bytes32) {
        return realitiov2.resultFor(question_id);
    }

    /// @notice Return the final answer to the specified question, provided it matches the specified criteria.
    /// @dev Reverts if the question is not finalized, or if it does not match the specified criteria.
    /// @param question_id The ID of the question
    /// @param content_hash The hash of the question content (template ID + opening time + question parameter string)
    /// @param arbitrator The arbitrator chosen for the question (regardless of whether they are asked to arbitrate)
    /// @param min_timeout The timeout set in the initial question settings must be this high or higher
    /// @param min_bond The bond sent with the final answer must be this high or higher
    /// @return The answer formatted as a bytes32
    function getFinalAnswerIfMatches(
        bytes32 question_id,
        bytes32 content_hash,
        address arbitrator,
        uint32 min_timeout,
        uint256 min_bond
    ) external view override returns (bytes32) {
        return realitiov2.getFinalAnswerIfMatches(question_id, content_hash, arbitrator, min_timeout, min_bond);
    }

    /// @notice Assigns the winnings (bounty and bonds) to everyone who gave the accepted answer
    /// Caller must provide the answer history, in reverse order
    /// @dev Works up the chain and assign bonds to the person who gave the right answer
    /// If someone gave the winning answer earlier, they must get paid from the higher bond
    /// That means we can't pay out the bond added at n until we have looked at n-1
    /// The first answer is authenticated by checking against the stored history_hash.
    /// One of the inputs to history_hash is the history_hash before it, so we use that to authenticate the next entry, etc
    /// Once we get to a null hash we'll know we're done and there are no more answers.
    /// Usually you would call the whole thing in a single transaction, but if not then the data is persisted to pick up later.
    /// @param question_id The ID of the question
    /// @param history_hashes Second-last-to-first, the hash of each history entry. (Final one should be empty).
    /// @param addrs Last-to-first, the address of each answerer or commitment sender
    /// @param bonds Last-to-first, the bond supplied with each answer or commitment
    /// @param answers Last-to-first, each answer supplied, or commitment ID if the answer was supplied with commit->reveal
    function claimWinnings(
        bytes32 question_id,
        bytes32[] calldata history_hashes,
        address[] calldata addrs,
        uint256[] calldata bonds,
        bytes32[] calldata answers
    ) public override {
        return realitiov2.claimWinnings(question_id, history_hashes, addrs, bonds, answers);
    }

    /// @notice Convenience function to assign bounties/bonds for multiple questions in one go, then withdraw all your funds.
    /// Caller must provide the answer history for each question, in reverse order
    /// @dev Can be called by anyone to assign bonds/bounties, but funds are only withdrawn for the user making the call.
    /// @param question_ids The IDs of the questions you want to claim for
    /// @param lengths The number of history entries you will supply for each question ID
    /// @param hist_hashes In a single list for all supplied questions, the hash of each history entry.
    /// @param addrs In a single list for all supplied questions, the address of each answerer or commitment sender
    /// @param bonds In a single list for all supplied questions, the bond supplied with each answer or commitment
    /// @param answers In a single list for all supplied questions, each answer supplied, or commitment ID
    function claimMultipleAndWithdrawBalance(
        bytes32[] calldata question_ids,
        uint256[] calldata lengths,
        bytes32[] calldata hist_hashes,
        address[] calldata addrs,
        uint256[] calldata bonds,
        bytes32[] calldata answers
    ) public override {
        return realitiov2.claimMultipleAndWithdrawBalance(question_ids, lengths, hist_hashes, addrs, bonds, answers);
    }

    /// @notice Returns the questions's content hash, identifying the question content
    /// @param question_id The ID of the question
    function getContentHash(bytes32 question_id) public view override returns (bytes32) {
        return realitiov2.getContentHash(question_id);
    }

    /// @notice Returns the arbitrator address for the question
    /// @param question_id The ID of the question
    function getArbitrator(bytes32 question_id) public view override returns (address) {
        return realitiov2.getArbitrator(question_id);
    }

    /// @notice Returns the timestamp when the question can first be answered
    /// @param question_id The ID of the question
    function getOpeningTS(bytes32 question_id) public view override returns (uint32) {
        return realitiov2.getOpeningTS(question_id);
    }

    /// @notice Returns the timeout in seconds used after each answer
    /// @param question_id The ID of the question
    function getTimeout(bytes32 question_id) public view override returns (uint32) {
        return realitiov2.getTimeout(question_id);
    }

    /// @notice Returns the timestamp at which the question will be/was finalized
    /// @param question_id The ID of the question
    function getFinalizeTS(bytes32 question_id) public view override returns (uint32) {
        return realitiov2.getFinalizeTS(question_id);
    }

    /// @notice Returns whether the question is pending arbitration
    /// @param question_id The ID of the question
    function isPendingArbitration(bytes32 question_id) public view override returns (bool) {
        return realitiov2.isPendingArbitration(question_id);
    }

    /// @notice Returns the current total unclaimed bounty
    /// @dev Set back to zero once the bounty has been claimed
    /// @param question_id The ID of the question
    function getBounty(bytes32 question_id) public view override returns (uint256) {
        return realitiov2.getBounty(question_id);
    }

    /// @notice Returns the current best answer
    /// @param question_id The ID of the question
    function getBestAnswer(bytes32 question_id) public view override returns (bytes32) {
        return realitiov2.getBestAnswer(question_id);
    }

    /// @notice Returns the history hash of the question
    /// @param question_id The ID of the question
    /// @dev Updated on each answer, then rewound as each is claimed
    function getHistoryHash(bytes32 question_id) public view override returns (bytes32) {
        return realitiov2.getHistoryHash(question_id);
    }

    /// @notice Returns the highest bond posted so far for a question
    /// @param question_id The ID of the question
    function getBond(bytes32 question_id) public view override returns (uint256) {
        return realitiov2.getBond(question_id);
    }

    function arbitrator_question_fees(address arbitrator) external view override returns (uint256) {
        return realitiov2.arbitrator_question_fees(arbitrator);
    }

    function balanceOf(address beneficiary) public view override returns (uint256) {
        return realitiov2.balanceOf(beneficiary);
    }

    function commitments(bytes32 id) public view override returns (Commitment memory) {
        return realitiov2.commitments(id);
    }

    function question_claims(bytes32 id) public view override returns (Claim memory) {
        return realitiov2.question_claims(id);
    }

    function template_hashes(uint256 id) public view override returns (bytes32) {
        return realitiov2.template_hashes(id);
    }

    function templates(uint256 id) public view override returns (uint256) {
        return realitiov2.templates(id);
    }

    function withdraw() public override {
        return realitiov2.withdraw();
    }

    function questions(bytes32 id) public view override returns (Question memory) {
        return realitiov2.questions(id);
    }
}
