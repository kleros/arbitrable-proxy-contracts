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

contract RealitioProxyWithAppeals is IRealitio, IDisputeResolver {
    IRealitio public realitioImplementation;
    uint256 private constant NO_OF_RULING_OPTIONS = (2**256) - 2; // The amount of non 0 choices the arbitrator can give. The uint256(-1) number of choices can not be used in the current Kleros Court implementation.
    bytes public arbitratorExtraData; // Extra data to require particular dispute and appeal behaviour. First 64 characters contain subcourtID and the second 64 characters contain number of votes in the jury.
    IArbitrator public immutable arbitrator; // The arbitrator contract.
    address public governor = msg.sender; // The address that can make governance changes.

    enum Status {
        None, // The question hasn't been requested arbitration yet.
        Disputed, // The question has been requested arbitration.
        Ruled, // The question has been ruled by arbitrator.
        Reported // The answer of the question has been reported to Realitio.
    }

    struct QuestionArbitrationData {
        address disputer; // The address that requested the arbitration.
        Status status; // The current status of the question.
        uint256 disputeID; // The ID of the dispute raised in the arbitrator contract.
        bytes32 answer; // The answer given by the arbitrator.
        Round[] rounds; // Tracks each appeal round of a dispute.
    }

    struct Round {
        mapping(uint256 => uint256) paidFees; // Tracks the fees paid in this round in the form paidFees[answer].
        mapping(uint256 => bool) hasPaid; // True if the fees for this particular answer has been fully paid in the form hasPaid[answer].
        mapping(address => mapping(uint256 => uint256)) contributions; // Maps contributors to their contributions for each answer in the form contributions[address][answer].
        uint256 feeRewards; // Sum of reimbursable appeal fees available to the parties that made contributions to the answer that ultimately wins a dispute.
        uint256[] fundedAnswers; // Stores the answer choices that are fully funded.
    }

    using RealitioSafeMath256 for uint256;
    using RealitioSafeMath32 for uint32;

    mapping(bytes32 => QuestionArbitrationData) public questionArbitrationDatas; // Maps a question ID to its data. questions[questionID].
    uint256 public metaEvidenceUpdates; // The number of times the meta evidence has been updated. Used to track the latest meta evidence ID.
    mapping(uint256 => bytes32) public disputeIDtoQuestionID; // Arbitrator dispute ids to  question ids.

    /// @notice Constructor, sets up some initial templates
    /// @dev Creates some generalized templates for different question types used in the DApp.
    constructor(
        IRealitio _realitioImplementation,
        IArbitrator _arbitrator,
        bytes memory _arbitratorExtraData
    ) {
        realitioImplementation = _realitioImplementation;
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
    }

    /** @dev Updates the meta evidence used for disputes.
     *  @param _metaEvidence URI to the new meta evidence file.
     */
    function changeMetaEvidence(string calldata _metaEvidence) external {
        require(msg.sender == governor, "Only governor can execute this");
        metaEvidenceUpdates++;
        emit MetaEvidence(metaEvidenceUpdates, _metaEvidence);
    }

    /// @notice Notify the contract that the arbitrator has been paid for a question, freezing it pending their decision.
    /// @dev The arbitrator contract is trusted to only call this if they've been paid, and tell us who paid them.
    /// @param questionID The ID of the question
    /// @param max_previous If specified, reverts if a bond higher than this was submitted after you sent your transaction.
    function requestArbitration(bytes32 questionID, uint256 max_previous) external payable {
        QuestionArbitrationData storage question = questionArbitrationDatas[questionID];
        require(question.status == Status.None, "Arbitration already requested");

        // Notify Kleros
        uint256 disputeID = arbitrator.createDispute{value: msg.value}(NO_OF_RULING_OPTIONS, arbitratorExtraData);
        emit Dispute(arbitrator, disputeID, metaEvidenceUpdates, uint256(questionID));
        disputeIDtoQuestionID[disputeID] = questionID;

        // Update internal state
        question.disputer = msg.sender;
        question.status = Status.Disputed;
        question.disputeID = disputeID;
        question.rounds.push();

        // Notify Realitio
        realitioImplementation.notifyOfArbitrationRequest(questionID, msg.sender, max_previous);
    }

    /** @dev Returns number of possible ruling options. Valid rulings are [0, return value].
     *  @param disputeID Dispute id as in arbitrable contract.
     *  @return count The number of ruling options.
     */
    function numberOfRulingOptions(uint256 disputeID) external view override returns (uint256 count) {
        return NO_OF_RULING_OPTIONS;
    }

    function rule(uint256 _disputeID, uint256 _ruling) public override {
        bytes32 questionID = disputeIDtoQuestionID[_disputeID];
        QuestionArbitrationData storage questionDispute = questionArbitrationDatas[questionID];

        Round storage round = questionDispute.rounds[questionDispute.rounds.length - 1];
        uint256 finalRuling = (round.fundedAnswers.length == 1) ? round.fundedAnswers[0] : _ruling;

        questionDispute.answer = bytes32(finalRuling + 1); // Shift Kleros ruling by +1 to match Realitio layout
        questionDispute.status = Status.Ruled;

        // Notify Kleros
        emit Ruling(IArbitrator(msg.sender), _disputeID, finalRuling);
    }

    function _verifyHistoryInputOrRevert(
        bytes32 last_history_hash,
        bytes32 history_hash,
        bytes32 answer,
        uint256 bond,
        address addr
    ) internal pure returns (bool) {
        if (last_history_hash == keccak256(abi.encodePacked(history_hash, answer, bond, addr, true))) {
            return true;
        }
        if (last_history_hash == keccak256(abi.encodePacked(history_hash, answer, bond, addr, false))) {
            return false;
        }
        revert("History input provided did not match the expected hash");
    }

    /** @dev Reports the answer to a specified question from the ERC792 arbitrator to the Realitio contract.
     *  @param _questionID The ID of the question.
     *  @param _lastHistoryHash The history hash given with the last answer to the question in the Realitio contract.
     *  @param _lastAnswerOrCommitmentID The last answer given, or its commitment ID if it was a commitment, to the question in the Realitio contract, in bytes32.
     *  @param _lastBond The bond paid for the last answer to the question in the Realitio contract.
     *  @param _lastAnswerer The last answerer to the question in the Realitio contract.
     */
    function reportAnswer(
        bytes32 _questionID,
        bytes32 _lastHistoryHash,
        bytes32 _lastAnswerOrCommitmentID,
        uint256 _lastBond,
        address _lastAnswerer
    ) external {
        QuestionArbitrationData storage questionDispute = questionArbitrationDatas[_questionID];
        require(questionDispute.status == Status.Ruled, "The status should be Ruled.");

        Question memory question = realitioImplementation.questions(_questionID);
        // bool is_commitment = _verifyHistoryInputOrRevert(question.history_hash, _lastHistoryHash, _lastAnswerOrCommitmentID, question.bond, _lastAnswerer);

        questionDispute.status = Status.Reported;

        realitioImplementation.assignWinnerAndSubmitAnswerByArbitrator(_questionID, questionDispute.answer, questionDispute.disputer, _lastHistoryHash, _lastAnswerOrCommitmentID, _lastAnswerer);
    }

    /** @dev Allows to submit evidence for a given dispute.
     *  @param _disputeID Dispute id as in arbitrable contract.
     *  @param  _evidenceURI Link to evidence.
     */
    function submitEvidence(uint256 _disputeID, string calldata _evidenceURI) external override {
        bytes32 questionID = disputeIDtoQuestionID[_disputeID];
        QuestionArbitrationData storage questionDispute = questionArbitrationDatas[questionID];

        require(questionDispute.status < Status.Ruled, "Cannot submit evidence to a resolved dispute.");

        emit Evidence(arbitrator, _disputeID, msg.sender, _evidenceURI);
    }

    /** @dev TRUSTED. Manages contributions and calls appeal function of the specified arbitrator to appeal a dispute. This function lets appeals be crowdfunded.
        Note that we don’t need to check that msg.value is enough to pay arbitration fees as it’s the responsibility of the arbitrator contract.
     *  @param disputeID Dispute id as in arbitrable contract.
     *  @param ruling The ruling option to which the caller wants to contribute.
     *  @return fullyFunded True if the ruling option got fully funded as a result of this contribution.
     */
    function fundAppeal(uint256 disputeID, uint256 ruling) external payable override returns (bool fullyFunded) {
        return true;
    }

    /** @dev Returns stake multipliers.
     *  @return winnerStakeMultiplier Winners stake multiplier.
     *  @return loserStakeMultiplier Losers stake multiplier.
     *  @return tieStakeMultiplier Stake multiplier in case of a tie (ruling 0).
     *  @return loserAppealPeriodMultiplier Losers appeal period multiplier. The loser is given less time to fund its appeal to defend against last minute appeal funding attacks.
     *  @return divisor Multiplier divisor in basis points.
     */
    function getMultipliers()
        public
        view
        override
        returns (
            uint256 winnerStakeMultiplier,
            uint256 loserStakeMultiplier,
            uint256 tieStakeMultiplier,
            uint256 loserAppealPeriodMultiplier,
            uint256 divisor
        )
    {
        return (0, 0, 0, 0, 0);
    }

    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved.
     *  @param disputeID Dispute id as in arbitrable contract.
     *  @param contributor The address to withdraw its rewards.
     *  @param roundNumber The number of the round caller wants to withdraw from.
     *  @param ruling A ruling option that the caller wants to withdraw fees and rewards related to it.
     */
    function withdrawFeesAndRewards(
        uint256 disputeID,
        address payable contributor,
        uint256 roundNumber,
        uint256 ruling
    ) external override returns (uint256 sum) {
        return 0;
    }

    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved. For multiple ruling options at once.
     *  @param disputeID Dispute id as in arbitrable contract.
     *  @param contributor The address to withdraw its rewards.
     *  @param roundNumber The number of the round caller wants to withdraw from.
     *  @param contributedTo Rulings that received contributions from contributor.
     */
    function withdrawFeesAndRewardsForMultipleRulings(
        uint256 disputeID,
        address payable contributor,
        uint256 roundNumber,
        uint256[] memory contributedTo
    ) external override {
        return;
    }

    /** @dev Allows to withdraw any rewards or reimbursable fees after the dispute gets resolved. For multiple rulings options and for all rounds at once.
     *  @param disputeID Dispute id as in arbitrable contract.
     *  @param contributor The address to withdraw its rewards.
     *  @param contributedTo Rulings that received contributions from contributor.
     */
    function withdrawFeesAndRewardsForAllRounds(
        uint256 disputeID,
        address payable contributor,
        uint256[] memory contributedTo
    ) external override {
        return;
    }

    /** @dev Returns the sum of withdrawable amount.
     *  @param disputeID Dispute id as in arbitrable contract.
     *  @param contributor The contributor for which to query.
     *  @param contributedTo Ruling options to look for potential withdrawals.
     *  @return sum The total amount available to withdraw.
     */
    function getTotalWithdrawableAmount(
        uint256 disputeID,
        address payable contributor,
        uint256[] memory contributedTo
    ) public view override returns (uint256 sum) {
        return 0;
    }

    /* The rest of the contract just redirects function calls: no extra logic implemented */

    /// @notice Notify the contract that the arbitrator has been paid for a question, freezing it pending their decision.
    /// @dev The arbitrator contract is trusted to only call this if they've been paid, and tell us who paid them.
    /// @param questionID The ID of the question
    /// @param requester The account that requested arbitration
    /// @param max_previous If specified, reverts if a bond higher than this was submitted after you sent your transaction.
    function notifyOfArbitrationRequest(
        bytes32 questionID,
        address requester,
        uint256 max_previous
    ) external override {
        return realitioImplementation.notifyOfArbitrationRequest(questionID, requester, max_previous);
    }

    /// @notice Function for arbitrator to set an optional per-question fee.
    /// @dev The per-question fee, charged when a question is asked, is intended as an anti-spam measure.
    /// @param fee The fee to be charged by the arbitrator when a question is asked
    function setQuestionFee(uint256 fee) external override {
        return realitioImplementation.setQuestionFee(fee);
    }

    /// @notice Create a reusable template, which should be a JSON document.
    /// Placeholders should use gettext() syntax, eg %s.
    /// @dev Template data is only stored in the event logs, but its block number is kept in contract storage.
    /// @param content The template content
    /// @return The ID of the newly-created template, which is created sequentially.
    function createTemplate(string calldata content) public override returns (uint256) {
        return realitioImplementation.createTemplate(content);
    }

    /// @notice Create a new reusable template and use it to ask a question
    /// @dev Template data is only stored in the event logs, but its block number is kept in contract storage.
    /// @param content The template content
    /// @param question A string containing the parameters that will be passed into the template to make the question
    /// @param arbitrator_ The arbitration contract that will have the final word on the answer if there is a dispute
    /// @param timeout How long the contract should wait after the answer is changed before finalizing on that answer
    /// @param opening_ts If set, the earliest time it should be possible to answer the question.
    /// @param nonce A user-specified nonce used in the question ID. Change it to repeat a question.
    /// @return The ID of the newly-created template, which is created sequentially.
    function createTemplateAndAskQuestion(
        string calldata content,
        string calldata question,
        address arbitrator_,
        uint32 timeout,
        uint32 opening_ts,
        uint256 nonce
    ) public payable override returns (bytes32) {
        uint256 template_id = createTemplate(content);
        return askQuestion(template_id, question, arbitrator_, timeout, opening_ts, nonce);
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
        return realitioImplementation.askQuestion(template_id, question, arbitrator, timeout, opening_ts, nonce);
    }

    /// @notice Add funds to the bounty for a question
    /// @dev Add bounty funds after the initial question creation. Can be done any time until the question is finalized.
    /// @param questionID The ID of the question you wish to fund
    function fundAnswerBounty(bytes32 questionID) external payable override {
        return realitioImplementation.fundAnswerBounty(questionID);
    }

    /// @notice Submit an answer for a question.
    /// @dev Adds the answer to the history and updates the current "best" answer.
    /// May be subject to front-running attacks; Substitute submitAnswerCommitment()->submitAnswerReveal() to prevent them.
    /// @param questionID The ID of the question
    /// @param answer The answer, encoded into bytes32
    /// @param max_previous If specified, reverts if a bond higher than this was submitted after you sent your transaction.
    function submitAnswer(
        bytes32 questionID,
        bytes32 answer,
        uint256 max_previous
    ) external payable override {
        return realitioImplementation.submitAnswer(questionID, answer, max_previous);
    }

    /// @notice Submit an answer for a question, crediting it to the specified account.
    /// @dev Adds the answer to the history and updates the current "best" answer.
    /// May be subject to front-running attacks; Substitute submitAnswerCommitment()->submitAnswerReveal() to prevent them.
    /// @param questionID The ID of the question
    /// @param answer The answer, encoded into bytes32
    /// @param max_previous If specified, reverts if a bond higher than this was submitted after you sent your transaction.
    /// @param answerer The account to which the answer should be credited
    function submitAnswerFor(
        bytes32 questionID,
        bytes32 answer,
        uint256 max_previous,
        address answerer
    ) external payable override {
        return realitioImplementation.submitAnswerFor(questionID, answer, max_previous, answerer);
    }

    /// @notice Submit the hash of an answer, laying your claim to that answer if you reveal it in a subsequent transaction.
    /// @dev Creates a hash, commitment_id, uniquely identifying this answer, to this question, with this bond.
    /// The commitment_id is stored in the answer history where the answer would normally go.
    /// Does not update the current best answer - this is left to the later submitAnswerReveal() transaction.
    /// @param questionID The ID of the question
    /// @param answer_hash The hash of your answer, plus a nonce that you will later reveal
    /// @param max_previous If specified, reverts if a bond higher than this was submitted after you sent your transaction.
    /// @param _answerer If specified, the address to be given as the question answerer. Defaults to the sender.
    /// @dev Specifying the answerer is useful if you want to delegate the commit-and-reveal to a third-party.
    function submitAnswerCommitment(
        bytes32 questionID,
        bytes32 answer_hash,
        uint256 max_previous,
        address _answerer
    ) external payable override {
        return realitioImplementation.submitAnswerCommitment(questionID, answer_hash, max_previous, _answerer);
    }

    /// @notice Submit the answer whose hash you sent in a previous submitAnswerCommitment() transaction
    /// @dev Checks the parameters supplied recreate an existing commitment, and stores the revealed answer
    /// Updates the current answer unless someone has since supplied a new answer with a higher bond
    /// msg.sender is intentionally not restricted to the user who originally sent the commitment;
    /// For example, the user may want to provide the answer+nonce to a third-party service and let them send the tx
    /// NB If we are pending arbitration, it will be up to the arbitrator to wait and see any outstanding reveal is sent
    /// @param questionID The ID of the question
    /// @param answer The answer, encoded as bytes32
    /// @param nonce The nonce that, combined with the answer, recreates the answer_hash you gave in submitAnswerCommitment()
    /// @param bond The bond that you paid in your submitAnswerCommitment() transaction
    function submitAnswerReveal(
        bytes32 questionID,
        bytes32 answer,
        uint256 nonce,
        uint256 bond
    ) external override {
        return realitioImplementation.submitAnswerReveal(questionID, answer, nonce, bond);
    }

    /// @notice Cancel a previously-requested arbitration and extend the timeout
    /// @dev Useful when doing arbitration across chains that can't be requested atomically
    /// @param questionID The ID of the question
    function cancelArbitration(bytes32 questionID) external override {
        revert("Unsupported operation.");
    }

    /// @notice Submit the answer for a question, for use by the arbitrator.
    /// @dev Doesn't require (or allow) a bond.
    /// If the current final answer is correct, the account should be whoever submitted it.
    /// If the current final answer is wrong, the account should be whoever paid for arbitration.
    /// However, the answerer stipulations are not enforced by the contract.
    /// @param questionID The ID of the question
    /// @param answer The answer, encoded into bytes32
    /// @param answerer The account credited with this answer for the purpose of bond claims
    function submitAnswerByArbitrator(
        bytes32 questionID,
        bytes32 answer,
        address answerer
    ) public override {
        return;
    }

    /// @notice Submit the answer for a question, for use by the arbitrator, working out the appropriate winner based on the last answer details.
    /// @dev Doesn't require (or allow) a bond.
    /// @param questionID The ID of the question
    /// @param answer The answer, encoded into bytes32
    /// @param payee_if_wrong The account to by credited as winner if the last answer given is wrong, usually the account that paid the arbitrator
    /// @param last_history_hash The history hash before the final one
    /// @param last_answer_or_commitment_id The last answer given, or the commitment ID if it was a commitment.
    /// @param last_answerer The address that supplied the last answer
    function assignWinnerAndSubmitAnswerByArbitrator(
        bytes32 questionID,
        bytes32 answer,
        address payee_if_wrong,
        bytes32 last_history_hash,
        bytes32 last_answer_or_commitment_id,
        address last_answerer
    ) external override {
        return;
    }

    /// @notice Report whether the answer to the specified question is finalized
    /// @param questionID The ID of the question
    /// @return Return true if finalized
    function isFinalized(bytes32 questionID) public view override returns (bool) {
        return realitioImplementation.isFinalized(questionID);
    }

    /// @notice (Deprecated) Return the final answer to the specified question, or revert if there isn't one
    /// @param questionID The ID of the question
    /// @return The answer formatted as a bytes32
    function getFinalAnswer(bytes32 questionID) external view override returns (bytes32) {
        return realitioImplementation.getFinalAnswer(questionID);
    }

    /// @notice Return the final answer to the specified question, or revert if there isn't one
    /// @param questionID The ID of the question
    /// @return The answer formatted as a bytes32
    function resultFor(bytes32 questionID) external view override returns (bytes32) {
        return realitioImplementation.resultFor(questionID);
    }

    /// @notice Return the final answer to the specified question, provided it matches the specified criteria.
    /// @dev Reverts if the question is not finalized, or if it does not match the specified criteria.
    /// @param questionID The ID of the question
    /// @param content_hash The hash of the question content (template ID + opening time + question parameter string)
    /// @param arbitrator The arbitrator chosen for the question (regardless of whether they are asked to arbitrate)
    /// @param min_timeout The timeout set in the initial question settings must be this high or higher
    /// @param min_bond The bond sent with the final answer must be this high or higher
    /// @return The answer formatted as a bytes32
    function getFinalAnswerIfMatches(
        bytes32 questionID,
        bytes32 content_hash,
        address arbitrator,
        uint32 min_timeout,
        uint256 min_bond
    ) external view override returns (bytes32) {
        return realitioImplementation.getFinalAnswerIfMatches(questionID, content_hash, arbitrator, min_timeout, min_bond);
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
    /// @param questionID The ID of the question
    /// @param history_hashes Second-last-to-first, the hash of each history entry. (Final one should be empty).
    /// @param addrs Last-to-first, the address of each answerer or commitment sender
    /// @param bonds Last-to-first, the bond supplied with each answer or commitment
    /// @param answers Last-to-first, each answer supplied, or commitment ID if the answer was supplied with commit->reveal
    function claimWinnings(
        bytes32 questionID,
        bytes32[] calldata history_hashes,
        address[] calldata addrs,
        uint256[] calldata bonds,
        bytes32[] calldata answers
    ) public override {
        return realitioImplementation.claimWinnings(questionID, history_hashes, addrs, bonds, answers);
    }

    /// @notice Returns the questions's content hash, identifying the question content
    /// @param questionID The ID of the question
    function getContentHash(bytes32 questionID) public view override returns (bytes32) {
        return realitioImplementation.getContentHash(questionID);
    }

    /// @notice Returns the arbitrator address for the question
    /// @param questionID The ID of the question
    function getArbitrator(bytes32 questionID) public view override returns (address) {
        return realitioImplementation.getArbitrator(questionID);
    }

    /// @notice Returns the timestamp when the question can first be answered
    /// @param questionID The ID of the question
    function getOpeningTS(bytes32 questionID) public view override returns (uint32) {
        return realitioImplementation.getOpeningTS(questionID);
    }

    /// @notice Returns the timeout in seconds used after each answer
    /// @param questionID The ID of the question
    function getTimeout(bytes32 questionID) public view override returns (uint32) {
        return realitioImplementation.getTimeout(questionID);
    }

    /// @notice Returns the timestamp at which the question will be/was finalized
    /// @param questionID The ID of the question
    function getFinalizeTS(bytes32 questionID) public view override returns (uint32) {
        return realitioImplementation.getFinalizeTS(questionID);
    }

    /// @notice Returns whether the question is pending arbitration
    /// @param questionID The ID of the question
    function isPendingArbitration(bytes32 questionID) public view override returns (bool) {
        return realitioImplementation.isPendingArbitration(questionID);
    }

    /// @notice Returns the current total unclaimed bounty
    /// @dev Set back to zero once the bounty has been claimed
    /// @param questionID The ID of the question
    function getBounty(bytes32 questionID) public view override returns (uint256) {
        return realitioImplementation.getBounty(questionID);
    }

    /// @notice Returns the current best answer
    /// @param questionID The ID of the question
    function getBestAnswer(bytes32 questionID) public view override returns (bytes32) {
        return realitioImplementation.getBestAnswer(questionID);
    }

    /// @notice Returns the history hash of the question
    /// @param questionID The ID of the question
    /// @dev Updated on each answer, then rewound as each is claimed
    function getHistoryHash(bytes32 questionID) public view override returns (bytes32) {
        return realitioImplementation.getHistoryHash(questionID);
    }

    /// @notice Returns the highest bond posted so far for a question
    /// @param questionID The ID of the question
    function getBond(bytes32 questionID) public view override returns (uint256) {
        return realitioImplementation.getBond(questionID);
    }

    function arbitrator_question_fees(address arbitrator) external view override returns (uint256) {
        return realitioImplementation.arbitrator_question_fees(arbitrator);
    }

    function balanceOf(address beneficiary) public view override returns (uint256) {
        return realitioImplementation.balanceOf(beneficiary);
    }

    function commitments(bytes32 id) public view override returns (Commitment memory) {
        return realitioImplementation.commitments(id);
    }

    function question_claims(bytes32 id) public view override returns (Claim memory) {
        return realitioImplementation.question_claims(id);
    }

    function template_hashes(uint256 id) public view override returns (bytes32) {
        return realitioImplementation.template_hashes(id);
    }

    function templates(uint256 id) public view override returns (uint256) {
        return realitioImplementation.templates(id);
    }

    function withdraw() public override {
        return realitioImplementation.withdraw();
    }

    function questions(bytes32 id) public view override returns (Question memory) {
        return realitioImplementation.questions(id);
    }
}
