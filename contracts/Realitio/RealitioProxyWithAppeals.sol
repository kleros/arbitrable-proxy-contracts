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
import "../IDisputeResolver.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

/**
 *  @title RealitioArbitratorProxyWithAppeals
 *  @dev A proxy contract for Realitio with extra logic to form an adapter between Kleros and Realitio. It notifies Realitio contract for arbitration requests and creates corresponding dispute on Kleros. Transmits Kleros ruling to Realitio contract. Maintains crowdfunded appeals and notifies Kleros contract. Provides a function to submit evidence for Kleros dispute.
 *  Disputes happen between the last answer and the challengers answer. But Kleros can rule for any valid answer as a response.
 *  There is a conversion between Kleros ruling and Realitio answer and there is a need for shifting by 1. For reviewers this should be a focus as it's quite easy to get confused. Any mistakes on this conversion will render this contract useless.
 *  NOTE: This contract trusts to the Kleros arbitrator and Realitio.
 */
contract RealitioProxyWithAppeals is IRealitio, IDisputeResolver {
    IRealitio public realitioImplementation; // Actual implementation of Realitio.
    uint256 private constant NO_OF_RULING_OPTIONS = (2**256) - 2; // The amount of non 0 choices the arbitrator can give. The uint256(-1) number of choices can not be used in the current Kleros Court implementation.
    bytes public arbitratorExtraData; // Extra data to require particular dispute and appeal behaviour. First 64 characters contain subcourtID and the second 64 characters contain number of votes in the jury.
    IArbitrator public immutable arbitrator; // The arbitrator contract. This will be Kleros arbitrator.
    address public governor = msg.sender; // The address that can make governance changes.

    // The required fee stake that a party must pay depends on who won the previous round and is proportional to the arbitration cost such that the fee stake for a round is stake multiplier * arbitration cost for that round.
    uint256 public winnerStakeMultiplier = 3000; // Multiplier of the arbitration cost that the winner has to pay as fee stake for a round in basis points. Default is 1x of appeal fee.
    uint256 public loserStakeMultiplier = 7000; // Multiplier of the arbitration cost that the loser has to pay as fee stake for a round in basis points. Default is 2x of appeal fee.
    uint256 public tieStakeMultiplier = 3000; // Multiplier of the arbitration cost that the parties has to pay as fee stake for a round in basis points, in case of tie. Default is 1x of appeal fee.
    uint256 public loserAppealPeriodMultiplier = 5000; // Multiplier of the appeal period for losers (any other ruling options) in basis points. Default is 1/2 of original appeal period.
    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    enum Status {
        None, // The question hasn't been requested arbitration yet.
        Disputed, // The question has been requested arbitration.
        Ruled, // The question has been ruled by arbitrator.
        Reported // The answer of the question has been reported to Realitio.
    }

    // To track internal state in this contract
    struct QuestionArbitrationData {
        address disputer; // The address that requested the arbitration.
        Status status; // The current status of the question.
        uint256 disputeID; // The ID of the dispute raised in the arbitrator contract.
        bytes32 answer; // The answer given by the arbitrator.
        Round[] rounds; // Tracks each appeal round of a dispute.
    }

    // For appeal logic
    struct Round {
        mapping(uint256 => uint256) paidFees; // Tracks the fees paid in this round in the form paidFees[answer].
        mapping(uint256 => bool) hasPaid; // True if the fees for this particular answer has been fully paid in the form hasPaid[answer].
        mapping(address => mapping(uint256 => uint256)) contributions; // Maps contributors to their contributions for each answer in the form contributions[address][answer].
        uint256 feeRewards; // Sum of reimbursable appeal fees available to the parties that made contributions to the answer that ultimately wins a dispute.
        uint256[] fundedRulings; // Stores the answer choices that are fully funded.
    }
    using CappedMath for uint256; // Operations bounded between 0 and 2**256 - 2. Note the 0 is reserver for invalid / refused to rule.

    mapping(bytes32 => QuestionArbitrationData) public questionArbitrationDatas; // Maps a question ID to its data.
    uint256 public metaEvidenceUpdates; // The number of times the meta evidence has been updated. Used to track the latest meta evidence ID.
    mapping(uint256 => bytes32) public disputeIDtoQuestionID; // Arbitrator dispute ids to question ids.

    /** @dev Constructor.
     *  @param _realitioImplementation The address of the Realitio contract.
     *  @param _arbitrator The address of the ERC792 arbitrator.
     *  @param _arbitratorExtraData The extra data used to raise a dispute in the ERC792 arbitrator.
     */
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
        emit MetaEvidence(metaEvidenceUpdates, _metaEvidence);
        metaEvidenceUpdates++;
    }

    /** @dev Sets the meta evidence. Can only be called once.
     *  @param _questionID The question id as in Realitio side.
     *  @param _maxPrevious If specified, reverts if a bond higher than this was submitted after you sent your transaction.
     */
    function requestArbitration(bytes32 _questionID, uint256 _maxPrevious) external payable returns (uint256 disputeID) {
        QuestionArbitrationData storage question = questionArbitrationDatas[_questionID];
        require(question.status == Status.None, "Arbitration already requested");

        // Notify Kleros
        disputeID = arbitrator.createDispute{value: msg.value}(NO_OF_RULING_OPTIONS, arbitratorExtraData);
        emit Dispute(arbitrator, disputeID, metaEvidenceUpdates, uint256(_questionID));
        disputeIDtoQuestionID[disputeID] = _questionID;

        // Update internal state
        question.disputer = msg.sender;
        question.status = Status.Disputed;
        question.disputeID = disputeID;
        question.rounds.push();

        // Notify Realitio
        realitioImplementation.notifyOfArbitrationRequest(_questionID, msg.sender, _maxPrevious);
    }

    /** @dev Reports the answer to a specified question from the Kleros arbitrator to the Realitio contract.
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

        questionDispute.status = Status.Reported;

        realitioImplementation.assignWinnerAndSubmitAnswerByArbitrator(_questionID, questionDispute.answer, questionDispute.disputer, _lastHistoryHash, _lastAnswerOrCommitmentID, _lastAnswerer);
    }

    /* Following section contains implementation of IDisputeResolver */

    /** @dev Returns number of possible ruling options. Valid rulings are [0, return value].
     *  @return count The number of ruling options.
     */
    function numberOfRulingOptions(IArbitrator, uint256) external view override returns (uint256 count) {
        return NO_OF_RULING_OPTIONS;
    }

    /** @dev Receives ruling from Kleros and executes consequences.
     *  @param _disputeID ID of Kleros dispute.
     *  @param _ruling Ruling that is given by Kleros. This needs to be converted to Realitio answer by shifting by 1.
     */
    function rule(uint256 _disputeID, uint256 _ruling) public override {
        bytes32 questionID = disputeIDtoQuestionID[_disputeID];
        QuestionArbitrationData storage questionDispute = questionArbitrationDatas[questionID];

        require(IArbitrator(msg.sender) == arbitrator, "Only arbitrator allowed");
        require(_ruling <= NO_OF_RULING_OPTIONS, "Invalid ruling");
        require(questionDispute.status == Status.Disputed, "Invalid arbitration status");

        Round storage round = questionDispute.rounds[questionDispute.rounds.length - 1];
        uint256 finalRuling = (round.fundedRulings.length == 1) ? round.fundedRulings[0] : _ruling;

        questionDispute.answer = bytes32(finalRuling - 1); // Shift Kleros ruling by +1 to match Realitio layout
        questionDispute.status = Status.Ruled;

        // Notify Kleros
        emit Ruling(IArbitrator(msg.sender), _disputeID, finalRuling);
    }

    /** @dev Allows to submit evidence for a given dispute.
     *  @param _disputeID Dispute id as in arbitrable contract.
     *  @param  _evidenceURI Link to evidence.
     */
    function submitEvidence(
        IArbitrator,
        uint256 _disputeID,
        string calldata _evidenceURI
    ) external override {
        bytes32 questionID = disputeIDtoQuestionID[_disputeID];
        QuestionArbitrationData storage questionDispute = questionArbitrationDatas[questionID];

        require(questionDispute.status < Status.Ruled, "Cannot submit evidence to a resolved dispute.");

        emit Evidence(arbitrator, _disputeID, msg.sender, _evidenceURI);
    }

    /** @dev Retrieves appeal cost for each ruling. It extends the function with the same name on the arbitrator side by adding
     *  _ruling parameter because total to be raised depends on multipliers.
     *  @param _disputeID The dispute this function returns its appeal costs.
     *  @param _ruling The ruling option which the caller wants to learn about its appeal cost.
     *  @param _currentRuling The ruling option which the caller wants to learn about its appeal cost.
     */
    function appealCost(
        uint256 _disputeID,
        uint256 _ruling,
        uint256 _currentRuling
    ) internal view returns (uint256 originalCost, uint256 specificCost) {
        uint256 multiplier;
        if (_currentRuling == 0) multiplier = tieStakeMultiplier;
        else if (_ruling == _currentRuling) multiplier = winnerStakeMultiplier;
        else multiplier = loserStakeMultiplier;

        uint256 appealFee = arbitrator.appealCost(_disputeID, arbitratorExtraData);
        return (appealFee, appealFee.addCap(appealFee.mulCap(multiplier) / MULTIPLIER_DIVISOR));
    }

    /** @dev Reverts if appeal period has expired for given ruling option. It gives less time for funding appeal for losing ruling option (in the last round).
     *  @param _disputeID Dispute ID of Kleros dispute.
     *  @param _ruling The ruling option to query for.
     *  @param _currentRuling The latest ruling given by Kleros. Note that this ruling is not final at this point, can be appealed.
     */
    function checkAppealPeriod(
        uint256 _disputeID,
        uint256 _ruling,
        uint256 _currentRuling
    ) internal view {
        (uint256 originalStart, uint256 originalEnd) = arbitrator.appealPeriod(_disputeID);

        if (_currentRuling == _ruling || _currentRuling == 0) require(block.timestamp >= originalStart && block.timestamp < originalEnd, "Funding must be made within the appeal period.");
        else {
            require(block.timestamp >= originalStart && block.timestamp < (originalStart + ((originalEnd - originalStart) * loserAppealPeriodMultiplier) / MULTIPLIER_DIVISOR), "Funding must be made within the appeal period.");
        }
    }

    /** @dev TRUSTED. Manages contributions and calls appeal function of the specified arbitrator to appeal a dispute. This function lets appeals be crowdfunded.
        Note that we don’t need to check that msg.value is enough to pay arbitration fees as it’s the responsibility of the arbitrator contract.
     *  @param _disputeID Dispute ID of Kleros dispute.
     *  @param _ruling The ruling option to which the caller wants to contribute to.
     *  @return fullyFunded True if the ruling option got fully funded as a result of this contribution.
     */
    function fundAppeal(
        IArbitrator,
        uint256 _disputeID,
        uint256 _ruling
    ) external payable override returns (bool fullyFunded) {
        require(_ruling <= NO_OF_RULING_OPTIONS, "Answer is out of bounds");
        bytes32 questionID = disputeIDtoQuestionID[_disputeID];
        QuestionArbitrationData storage questionDispute = questionArbitrationDatas[questionID];
        require(questionDispute.status == Status.Disputed, "No dispute to appeal.");

        uint256 currentRuling = arbitrator.currentRuling(_disputeID);

        checkAppealPeriod(_disputeID, _ruling, currentRuling);
        (uint256 originalCost, uint256 totalCost) = appealCost(_disputeID, _ruling, currentRuling);

        uint256 roundsLength = questionDispute.rounds.length;
        Round storage lastRound = questionDispute.rounds[roundsLength - 1];
        require(!lastRound.hasPaid[_ruling], "Appeal fee has already been paid.");
        uint256 paidFeesInLastRound = lastRound.paidFees[_ruling];

        uint256 contribution = totalCost.subCap(paidFeesInLastRound) > msg.value ? msg.value : totalCost.subCap(paidFeesInLastRound);
        emit Contribution(arbitrator, _disputeID, roundsLength - 1, _ruling, msg.sender, contribution);

        lastRound.contributions[msg.sender][_ruling] += contribution;

        if (paidFeesInLastRound >= totalCost) {
            lastRound.feeRewards += paidFeesInLastRound;
            lastRound.fundedRulings.push(_ruling);
            lastRound.hasPaid[_ruling] = true;
            emit RulingFunded(arbitrator, _disputeID, roundsLength - 1, _ruling);
        }

        if (lastRound.fundedRulings.length > 1) {
            // At least two ruling options are fully funded.
            questionDispute.rounds.push();

            lastRound.feeRewards = lastRound.feeRewards.subCap(originalCost);
            arbitrator.appeal{value: originalCost}(_disputeID, arbitratorExtraData);
        }

        msg.sender.transfer(msg.value.subCap(contribution)); // Sending extra value back to contributor.

        return lastRound.hasPaid[_ruling];
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
        return (winnerStakeMultiplier, loserStakeMultiplier, tieStakeMultiplier, loserAppealPeriodMultiplier, MULTIPLIER_DIVISOR);
    }

    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved.
     *  @param _disputeID Dispute ID of Kleros dispute.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _roundNumber The number of the round caller wants to withdraw from.
     *  @param _ruling A ruling option that the caller wants to withdraw fees and rewards related to it.
     */
    function withdrawFeesAndRewards(
        IArbitrator,
        uint256 _disputeID,
        address payable _contributor,
        uint256 _roundNumber,
        uint256 _ruling
    ) public override returns (uint256 amount) {
        bytes32 questionID = disputeIDtoQuestionID[_disputeID];
        QuestionArbitrationData storage questionDispute = questionArbitrationDatas[questionID];

        Round storage round = questionDispute.rounds[_roundNumber];

        require(questionDispute.status >= Status.Ruled, "There is no ruling yet.");

        if (!round.hasPaid[_ruling]) {
            // Allow to reimburse if funding was unsuccessful for this ruling option.
            amount = round.contributions[_contributor][_ruling];
        } else {
            // Funding was successful for this ruling option.
            if (_ruling == (uint256(questionDispute.answer) + 1)) {
                // This ruling option is the ultimate winner.
                uint256 paidFees = round.paidFees[_ruling];
                amount += paidFees > 0 ? (round.contributions[_contributor][_ruling] * round.feeRewards) / paidFees : 0;
            } else if (!round.hasPaid[uint256(questionDispute.answer) + 1]) {
                // This ruling option was not the ultimate winner, but the ultimate winner was not funded in this round. In this case funded ruling option(s) wins by default. Prize is distributed among contributors of funded ruling option(s).
                amount += (round.contributions[_contributor][_ruling] * round.feeRewards) / (round.paidFees[round.fundedRulings[0]] + round.paidFees[round.fundedRulings[1]]);
            }
        }

        round.contributions[_contributor][_ruling] = 0;
        if (amount != 0) {
            _contributor.send(amount); // User is responsible for accepting the reward.
            emit Withdrawal(arbitrator, _disputeID, _roundNumber, _ruling, _contributor, amount);
        }
    }

    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved. For multiple ruling options at once.
     *  @param _disputeID Dispute ID of Kleros dispute.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _roundNumber The number of the round caller wants to withdraw from.
     *  @param _contributedTo Rulings that received contributions from contributor.
     */
    function withdrawFeesAndRewardsForMultipleRulings(
        IArbitrator,
        uint256 _disputeID,
        address payable _contributor,
        uint256 _roundNumber,
        uint256[] memory _contributedTo
    ) public override {
        uint256 contributionArrayLength = _contributedTo.length;
        for (uint256 contributionNumber = 0; contributionNumber < contributionArrayLength; contributionNumber++) {
            withdrawFeesAndRewards(arbitrator, _disputeID, _contributor, _roundNumber, _contributedTo[contributionNumber]);
        }
    }

    /** @dev Allows to withdraw any rewards or reimbursable fees after the dispute gets resolved. For multiple rulings options and for all rounds at once.
     *  @param _disputeID Dispute ID of Kleros dispute.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _contributedTo Rulings that received contributions from contributor.
     */
    function withdrawFeesAndRewardsForAllRounds(
        IArbitrator,
        uint256 _disputeID,
        address payable _contributor,
        uint256[] memory _contributedTo
    ) external override {
        bytes32 questionID = disputeIDtoQuestionID[_disputeID];
        QuestionArbitrationData storage questionDispute = questionArbitrationDatas[questionID];
        uint256 noOfRounds = questionDispute.rounds.length;

        for (uint256 roundNumber = 0; roundNumber < noOfRounds; roundNumber++) {
            withdrawFeesAndRewardsForMultipleRulings(arbitrator, _disputeID, _contributor, roundNumber, _contributedTo);
        }
    }

    /** @dev Returns the sum of withdrawable amount.
     *  @param _disputeID Dispute ID of Kleros dispute.
     *  @param _contributor The contributor for which to query.
     *  @param _contributedTo Ruling options to look for potential withdrawals.
     *  @return sum The total amount available to withdraw.
     */
    function getTotalWithdrawableAmount(
        IArbitrator,
        uint256 _disputeID,
        address payable _contributor,
        uint256[] memory _contributedTo
    ) public view override returns (uint256 sum) {
        bytes32 questionID = disputeIDtoQuestionID[_disputeID];
        QuestionArbitrationData storage questionDispute = questionArbitrationDatas[questionID];
        uint256 noOfRounds = questionDispute.rounds.length;
        for (uint256 roundNumber = 0; roundNumber < noOfRounds; roundNumber++) {
            for (uint256 contributionNumber = 0; contributionNumber < _contributedTo.length; contributionNumber++) {
                Round storage round = questionDispute.rounds[roundNumber];
                uint256 finalRuling = uint256(questionDispute.answer) + 1;
                uint256 ruling = _contributedTo[contributionNumber];
                require(questionDispute.status >= Status.Ruled, "There is no ruling yet.");

                if (!round.hasPaid[ruling]) {
                    // Allow to reimburse if funding was unsuccessful for this ruling option.
                    sum += round.contributions[_contributor][ruling];
                } else {
                    //Funding was successful for this ruling option.
                    if (ruling == finalRuling) {
                        // This ruling option is the ultimate winner.
                        sum += round.paidFees[ruling] > 0 ? (round.contributions[_contributor][ruling] * round.feeRewards) / round.paidFees[ruling] : 0;
                    } else if (!round.hasPaid[finalRuling]) {
                        // This ruling option was not the ultimate winner, but the ultimate winner was not funded in this round. In this case funded ruling option(s) wins by default. Prize is distributed among contributors of funded ruling option(s).
                        sum += (round.contributions[_contributor][ruling] * round.feeRewards) / (round.paidFees[round.fundedRulings[0]] + round.paidFees[round.fundedRulings[1]]);
                    }
                }
            }
        }
    }

    /* The rest of the contract just redirects function calls to underlying Realitio implementation: no extra logic implemented */

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
    /// @param maxPrevious If specified, reverts if a bond higher than this was submitted after you sent your transaction.
    function submitAnswer(
        bytes32 questionID,
        bytes32 answer,
        uint256 maxPrevious
    ) external payable override {
        return realitioImplementation.submitAnswer(questionID, answer, maxPrevious);
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
    /// @param _arbitrator The arbitrator chosen for the question (regardless of whether they are asked to arbitrate)
    /// @param min_timeout The timeout set in the initial question settings must be this high or higher
    /// @param min_bond The bond sent with the final answer must be this high or higher
    /// @return The answer formatted as a bytes32
    function getFinalAnswerIfMatches(
        bytes32 questionID,
        bytes32 content_hash,
        address _arbitrator,
        uint32 min_timeout,
        uint256 min_bond
    ) external view override returns (bytes32) {
        return realitioImplementation.getFinalAnswerIfMatches(questionID, content_hash, _arbitrator, min_timeout, min_bond);
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
