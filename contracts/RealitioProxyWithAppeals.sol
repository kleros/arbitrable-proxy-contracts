// SPDX-License-Identifier: MIT

/**
 *  @authors: [@unknownunknown1]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity >=0.7;

/* solium-disable max-len*/
import "./IDisputeResolver.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

interface RealitioInterface {
    /** @dev Notify the Realitio contract that the arbitrator has been paid for a question, freezing it pending their decision.
     *  @param question_id The ID of the question.
     *  @param requester The address that requested arbitration.
     *  @param max_previous If specified, reverts if a bond higher than this was submitted after you sent your transaction.
     */
    function notifyOfArbitrationRequest(
        bytes32 question_id,
        address requester,
        uint256 max_previous
    ) external;

    /** @dev Report the answer to Realitio contract.
     *  @param question_id The ID of the question.
     *  @param answer The answer, encoded into bytes32.
     *  @param answerer The account credited with this answer for the purpose of bond claims.
     */
    function submitAnswerByArbitrator(
        bytes32 question_id,
        bytes32 answer,
        address answerer
    ) external;

    /** @dev Returns the history hash of the question.
     *  @param question_id The ID of the question.
     *  @return The history hash.
     */
    function getHistoryHash(bytes32 question_id) external returns (bytes32);

    /** @dev Returns the commitment info by its id.
     *  @param commitment_id The ID of the commitment.
     *  @return Time after which the committed answer can be revealed.
     *  @return Whether the commitment has already been revealed or not.
     *  @return The committed answer, encoded as bytes32.
     */
    function commitments(bytes32 commitment_id)
        external
        returns (
            uint32,
            bool,
            bytes32
        );
}

/**
 *  @title RealitioArbitratorProxy
 *  @dev A Realitio arbitrator that is just a proxy for an ERC792 arbitrator.
 *  This version of the contract supports the appeal crowdfunding and evidence submission.
 *  In order to fund an appeal only two possible answers have to be funded.
 *  The answer has a uint256 type to match the arbitrator's ruling.
 *  NOTE: This contract trusts that the Arbitrator is honest and will not reenter or modify its costs during a call.
 *  The arbitrator must support appeal period.
 */
contract RealitioArbitratorProxyWithAppeals is IDisputeResolver {
    using CappedMath for uint256;

    /* Constants */
    uint256 private constant NUMBER_OF_CHOICES = (2**256) - 2; // The amount of non 0 choices the arbitrator can give. The uint256(-1) number of choices can not be used in the current Kleros Court implementation.
    uint256 private constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    /* Storage */

    enum Status {
        None, // The question hasn't been requested arbitration yet.
        Disputed, // The question has been requested arbitration.
        Ruled, // The question has been ruled by arbitrator.
        Reported // The answer of the question has been reported to Realitio.
    }

    struct Question {
        address disputer; // The address that requested the arbitration.
        Status status; // The current status of the question.
        uint256 disputeID; // The ID of the dispute raised in the arbitrator contract.
        uint256 answer; // The answer given by the arbitrator.
        Round[] rounds; // Tracks each appeal round of a dispute.
    }

    // Round struct stores the contributions made to particular answers.
    struct Round {
        mapping(uint256 => uint256) paidFees; // Tracks the fees paid in this round in the form paidFees[answer].
        mapping(uint256 => bool) hasPaid; // True if the fees for this particular answer has been fully paid in the form hasPaid[answer].
        mapping(address => mapping(uint256 => uint256)) contributions; // Maps contributors to their contributions for each answer in the form contributions[address][answer].
        uint256 feeRewards; // Sum of reimbursable appeal fees available to the parties that made contributions to the answer that ultimately wins a dispute.
        uint256[] fundedAnswers; // Stores the answer choices that are fully funded.
    }

    address public governor = msg.sender; // The address that can make governance changes.
    
    IArbitrator public immutable arbitrator; // The arbitrator contract.
    bytes public arbitratorExtraData; // Extra data to require particular dispute and appeal behaviour.
    RealitioInterface public immutable realitio; // The address of the Realitio contract.
    uint256 public metaEvidenceUpdates; // The number of times the meta evidence has been updated. Used to track the latest meta evidence ID.

    // Multipliers are in basis points.
    uint256 private winnerMultiplier; // Multiplier for calculating the appeal fee that must be paid for the answer that was chosen by the arbitrator in the previous round.
    uint256 private loserMultiplier; // Multiplier for calculating the appeal fee that must be paid for the answer that the arbitrator didn't rule for in the previous round.
    uint256 private loserAppealPeriodMultiplier; // Multiplier for calculating the duration of the appeal period for the loser, in basis points.

    mapping(uint256 => Question) public questions; // Maps a question ID to its data. questions[questionID].
    mapping(uint256 => uint256) public override externalIDtoLocalID; // Maps external (arbitrator side) dispute ids to local dispute(question) ids.

    /* Modifiers */

    modifier onlyGovernor {
        require(msg.sender == governor, "The caller must be the governor.");
        _;
    }

    /* Events */

    /** @dev Constructor.
     *  @param _arbitrator The address of the ERC792 arbitrator.
     *  @param _arbitratorExtraData The extra data used to raise a dispute in the ERC792 arbitrator.
     *  @param _metaEvidence The URI of the meta evidence file.
     *  @param _realitio The address of the Realitio contract.
     *  @param _winnerMultiplier Multiplier for calculating the appeal cost of the winning answer.
     *  @param _loserMultiplier Multiplier for calculation the appeal cost of the losing answer.
     *  @param _loserAppealPeriodMultiplier Multiplier for calculating the appeal period for the answer that didn't win the previous round.
     */
    constructor(
        IArbitrator _arbitrator,
        bytes memory _arbitratorExtraData,
        string memory _metaEvidence,
        RealitioInterface _realitio,
        uint256 _winnerMultiplier,
        uint256 _loserMultiplier,
        uint256 _loserAppealPeriodMultiplier
    ) public {
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        realitio = _realitio;
        winnerMultiplier = _winnerMultiplier;
        loserMultiplier = _loserMultiplier;
        loserAppealPeriodMultiplier = _loserAppealPeriodMultiplier;
        
        emit MetaEvidence(0, _metaEvidence);
    }

    /* External and public */

    /** @dev Changes the proportion of appeal fees that must be added to appeal cost for the winning party.
     *  @param _winnerMultiplier The new winner multiplier value in basis points.
     */
    function changeWinnerMultiplier(uint256 _winnerMultiplier) external onlyGovernor {
        winnerMultiplier = _winnerMultiplier;
    }

    /** @dev Changes the proportion of appeal fees that must be added to appeal cost for the losing party.
     *  @param _loserMultiplier The new loser multiplier value in basis points.
     */
    function changeLoserMultiplier(uint256 _loserMultiplier) external onlyGovernor {
        loserMultiplier = _loserMultiplier;
    }

    /** @dev Changes the multiplier for calculating the duration of the appeal period for loser.
     *  @param _loserAppealPeriodMultiplier The new loser multiplier for the appeal period, in basis points.
     */
    function changeLoserAppealPeriodMultiplier(uint256 _loserAppealPeriodMultiplier) external onlyGovernor {
        loserAppealPeriodMultiplier = _loserAppealPeriodMultiplier;
    }

    /** @dev Changes the governor of the contract.
     *  @param _governor The address of the new governor.
     */
    function changeGovernor(address _governor) external onlyGovernor {
        governor = _governor;
    }

    /** @dev Updates the meta evidence used for disputes.
     *  @param _metaEvidence URI to the new meta evidence file.
     */
    function changeMetaEvidence(string calldata _metaEvidence) external onlyGovernor {
        metaEvidenceUpdates++;
        emit MetaEvidence(metaEvidenceUpdates, _metaEvidence);
    }

    /** @dev Raises a dispute from a specified question.
     *  @param _questionID The ID of the question, as in Realitio.
     *  @param _maxPrevious If specified, reverts if a bond higher than this was submitted after you sent your transaction.
     */
    function requestArbitration(bytes32 _questionID, uint256 _maxPrevious) external payable {
        uint256 questionID = uint256(_questionID);
        Question storage question = questions[questionID];
        require(question.status == Status.None, "Arbitration already requested");
        uint256 disputeID = arbitrator.createDispute{value: msg.value}(NUMBER_OF_CHOICES, arbitratorExtraData);

        question.disputer = msg.sender;
        question.status = Status.Disputed;
        question.disputeID = disputeID;
        question.rounds.push();
        externalIDtoLocalID[disputeID] = questionID;

        realitio.notifyOfArbitrationRequest(_questionID, msg.sender, _maxPrevious);
        emit Dispute(arbitrator, disputeID, metaEvidenceUpdates, questionID);
    }

    /** @dev Takes up to the total amount required to fund an answer. Reimburses the rest. Creates an appeal if at least two answers are funded.
     *  @param _questionID The ID of the question
     *  @param _answer One of the possible rulings the arbitrator can give that the funder considers to be the correct answer to the question.
     *  Note that the answer has Kleros denomination, meaning that it has '+1' offset compared to Realitio format.
     *  Also note that '0' answer can be funded.
     *  @return Whether the answer was fully funded or not.
     */
    function fundAppeal(uint256 _questionID, uint256 _answer) external payable override returns (bool) {
        require(_answer <= NUMBER_OF_CHOICES, "Answer is out of bounds");
        Question storage question = questions[_questionID];
        require(question.status == Status.Disputed, "No dispute to appeal.");
        uint256 disputeID = question.disputeID;
        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = arbitrator.appealPeriod(disputeID);
        require(block.timestamp >= appealPeriodStart && block.timestamp < appealPeriodEnd, "Appeal period is over");

        uint256 multiplier;
        {
            uint256 winner = arbitrator.currentRuling(disputeID);
            if (winner == _answer) {
                multiplier = winnerMultiplier;
            } else {
                require(
                    block.timestamp - appealPeriodStart < (appealPeriodEnd - appealPeriodStart).mulCap(loserAppealPeriodMultiplier) / MULTIPLIER_DIVISOR, 
                    "Appeal period is over for loser"
                );
                multiplier = loserMultiplier;
            }
        }
        
        uint256 lastRoundID = question.rounds.length - 1;
        Round storage round = question.rounds[lastRoundID];
        require(!round.hasPaid[_answer], "Appeal fee already been paid");
        uint256 appealCost = arbitrator.appealCost(disputeID, arbitratorExtraData);
        uint256 totalCost = appealCost.addCap((appealCost.mulCap(multiplier)) / MULTIPLIER_DIVISOR);

        // Take up to the amount necessary to fund the current round at the current costs.
        uint256 contribution = totalCost.subCap(round.paidFees[_answer]) > msg.value ? msg.value : totalCost.subCap(round.paidFees[_answer]);
        emit Contribution(_questionID, lastRoundID, _answer, msg.sender, contribution);

        round.contributions[msg.sender][_answer] += contribution;
        round.paidFees[_answer] += contribution;
        if (round.paidFees[_answer] >= totalCost) {
            round.feeRewards += round.paidFees[_answer];
            round.fundedAnswers.push(_answer);
            round.hasPaid[_answer] = true;
            emit RulingFunded(_questionID, lastRoundID, _answer);
        }

        if (round.fundedAnswers.length > 1) {
            // At least two sides are fully funded.
            question.rounds.push();

            round.feeRewards = round.feeRewards.subCap(appealCost);
            arbitrator.appeal{value: appealCost}(disputeID, arbitratorExtraData);
        }

        msg.sender.transfer(msg.value.subCap(contribution)); // Sending extra value back to contributor.
        return round.hasPaid[_answer];
    }

    /** @dev Sends the fee stake rewards and reimbursements proportional to the contributions made to the winner of a dispute. Reimburses contributions if there is no winner.
     *  @param _questionID The ID of the question.
     *  @param _beneficiary The address that made contributions.
     *  @param _round The round from which to withdraw.
     *  @param _answer The answer the beneficiary contributed to.
     *  @return reward The withdrawn amount.
     */
    function withdrawFeesAndRewards(
        uint256 _questionID,
        address payable _beneficiary,
        uint256 _round,
        uint256 _answer
    ) public override returns (uint256 reward) {
        Question storage question = questions[_questionID];
        Round storage round = question.rounds[_round];
        require(question.status > Status.Disputed, "Dispute not resolved");
        // Allow to reimburse if funding of the round was unsuccessful.
        if (!round.hasPaid[_answer]) {
            reward = round.contributions[_beneficiary][_answer];
        } else if (!round.hasPaid[question.answer]) {
            // Reimburse unspent fees proportionally if the ultimate winner didn't pay appeal fees fully.
            // Note that if only one side is funded it will become a winner and this part of the condition won't be reached.
            reward = round.fundedAnswers.length > 1
                ? (round.contributions[_beneficiary][_answer] * round.feeRewards) / (round.paidFees[round.fundedAnswers[0]] + round.paidFees[round.fundedAnswers[1]])
                : 0;
        } else if (question.answer == _answer) {
            uint256 paidFees = round.paidFees[_answer];
            // Reward the winner.
            reward = paidFees > 0 ? (round.contributions[_beneficiary][_answer] * round.feeRewards) / paidFees : 0;
        }

        if (reward != 0) {
            round.contributions[_beneficiary][_answer] = 0;
            _beneficiary.transfer(reward);
            emit Withdrawal(_questionID, _round, _answer, _beneficiary, reward);
        }
    }

    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved for multiple ruling options (answers) at once.
     *  @param _questionID The ID of the question.
     *  @param _beneficiary The address that made contributions.
     *  @param _round The round from which to withdraw.
     *  @param _contributedTo Answers that received contributions from contributor.
     */
    function withdrawFeesAndRewardsForMultipleRulings(
        uint256 _questionID,
        address payable _beneficiary,
        uint256 _round,
        uint256[] memory _contributedTo
    ) public override {
        for (uint256 contributionNumber = 0; contributionNumber < _contributedTo.length; contributionNumber++) {
            withdrawFeesAndRewards(_questionID, _beneficiary, _round, _contributedTo[contributionNumber]);
        }
    }

    /** @dev Allows to withdraw any rewards or reimbursable fees after the dispute gets resolved. For multiple rulings options (answers) and for all rounds at once.
     *  @param _questionID The ID of the question.
     *  @param _beneficiary The address that made contributions.
     *  @param _contributedTo Answers that received contributions from contributor.
     */
    function withdrawFeesAndRewardsForAllRounds(
        uint256 _questionID,
        address payable _beneficiary,
        uint256[] memory _contributedTo
    ) external override {
        for (uint256 roundNumber = 0; roundNumber < questions[_questionID].rounds.length; roundNumber++) {
            withdrawFeesAndRewardsForMultipleRulings(_questionID, _beneficiary, roundNumber, _contributedTo);
        }
    }

    /** @dev Reports the answer to a specified question from the ERC792 arbitrator to the Realitio contract.
     *  @param _questionID The ID of the question.
     *  @param _lastHistoryHash The history hash given with the last answer to the question in the Realitio contract.
     *  @param _lastAnswerOrCommitmentID The last answer given, or its commitment ID if it was a commitment, to the question in the Realitio contract, in bytes32.
     *  @param _lastBond The bond paid for the last answer to the question in the Realitio contract.
     *  @param _lastAnswerer The last answerer to the question in the Realitio contract.
     *  @param _isCommitment Whether the last answer to the question in the Realitio contract used commit or reveal or not. True if it did, false otherwise.
     */
    function reportAnswer(
        uint256 _questionID,
        bytes32 _lastHistoryHash,
        bytes32 _lastAnswerOrCommitmentID,
        uint256 _lastBond,
        address _lastAnswerer,
        bool _isCommitment
    ) external {
        Question storage question = questions[_questionID];
        require(question.status == Status.Ruled, "The status should be Ruled.");
        require(
            realitio.getHistoryHash(bytes32(_questionID)) == keccak256(abi.encodePacked(_lastHistoryHash, _lastAnswerOrCommitmentID, _lastBond, _lastAnswerer, _isCommitment)),
            "The hash does not match."
        );

        question.status = Status.Reported;
        // Realitio ruling is shifted by 1 compared to Kleros, so we subtract 1 to bring it to Realitio format.
        realitio.submitAnswerByArbitrator(bytes32(_questionID), bytes32(question.answer - 1), computeWinner(_questionID, _lastAnswerOrCommitmentID, _lastBond, _lastAnswerer, _isCommitment));
    }

    /** @dev Allows to submit evidence for a given dispute.
     *  @param _questionID The ID of the question.
     *  @param _evidenceURI Link to evidence.
     */
    function submitEvidence(uint256 _questionID, string calldata _evidenceURI) external override {
        Question storage question = questions[_questionID];
        require(question.status == Status.Disputed, "The status should be Disputed.");
        emit Evidence(arbitrator, _questionID, msg.sender, _evidenceURI);
    }

    /** @dev Gives a ruling for a dispute. Can only be called by the arbitrator.
     *  Accounts for the situation where the winner loses a case due to paying less appeal fees than expected.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Refuse to arbitrate".
     */
    function rule(uint256 _disputeID, uint256 _ruling) external override {
        uint256 questionID = externalIDtoLocalID[_disputeID];
        Question storage question = questions[questionID];
        require(msg.sender == address(arbitrator), "Caller must be arbitrator.");
        require(question.status == Status.Disputed, "Dispute is already ruled.");
        uint256 finalRuling = _ruling;

        // If one side paid its fees, the ruling is in its favor. Note that if the other side had also paid, an appeal would have been created.
        Round storage round = question.rounds[question.rounds.length - 1];
        if (round.fundedAnswers.length == 1) finalRuling = round.fundedAnswers[0];

        emit Ruling(IArbitrator(msg.sender), _disputeID, finalRuling);
        executeRuling(questionID, finalRuling);
    }

    /* External Views */

    /** @dev Returns stake multipliers.
     *  @return winner Winners stake multiplier.
     *  @return loser Losers stake multiplier.
     *  @return loserAppealPeriod Multiplier for calculating an appeal period duration for the losing side.
     *  @return divisor Multiplier divisor.
     */
    function getMultipliers()
        external
        view
        override
        returns (
            uint256 winner,
            uint256 loser,
            uint256 loserAppealPeriod,
            uint256 divisor
        )
    {
        return (winnerMultiplier, loserMultiplier, loserAppealPeriodMultiplier, MULTIPLIER_DIVISOR);
    }

    /** @dev Returns number of possible ruling options. Valid rulings are [0, return value].
     *  @param _questionID The ID of the question.
     *  @return count The number of ruling options.
     */
    function numberOfRulingOptions(uint256 _questionID) external pure override returns (uint256) {
        return NUMBER_OF_CHOICES;
    }

    /** @dev Gets the number of rounds of the specific question.
     *  @param _questionID The ID of the question.
     *  @return The number of rounds.
     */
    function getNumberOfRounds(uint256 _questionID) external view returns (uint256) {
        return questions[_questionID].rounds.length;
    }

    /** @dev Gets the information of a round of a question.
     *  @param _questionID The ID of the question.
     *  @param _round The round to query.
     *  @return paidFees The amount of fees paid for each fully funded answer.
     *  @return feeRewards The amount of fees that will be use as rewards.
     *  @return fundedAnswers IDs of fully funded answers.
     */
    function getRoundInfo(uint256 _questionID, uint256 _round)
        external
        view
        returns (
            uint256[] memory paidFees,
            uint256 feeRewards,
            uint256[] memory fundedAnswers
        )
    {
        Round storage round = questions[_questionID].rounds[_round];
        fundedAnswers = round.fundedAnswers;

        paidFees = new uint256[](round.fundedAnswers.length);

        for (uint256 i = 0; i < round.fundedAnswers.length; i++) {
            paidFees[i] = round.paidFees[round.fundedAnswers[i]];
        }

        feeRewards = round.feeRewards;
    }

    /** @dev Gets the information of a round of a question for a specific answer choice.
     *  @param _questionID The ID of the question.
     *  @param _round The round to query.
     *  @param _answer The answer choice to get funding status.
     *  @return raised The amount paid for this answer.
     *  @return fullyFunded Whether the answer is fully funded or not.
     */
    function getFundingStatus(
        uint256 _questionID,
        uint256 _round,
        uint256 _answer
    ) external view returns (uint256 raised, bool fullyFunded) {
        Round storage round = questions[_questionID].rounds[_round];
        raised = round.paidFees[_answer];
        fullyFunded = round.hasPaid[_answer];
    }

    /** @dev Gets contributions to the answers that are fully funded.
     *  @param _questionID The ID of the question.
     *  @param _round The round to query.
     *  @param _contributor The address whose contributions to query.
     *  @return fundedAnswers IDs of the answers that are fully funded.
     *  @return contributions The amount contributed to each funded answer by the contributor.
     */
    function getContributionsToSuccessfulFundings(
        uint256 _questionID,
        uint256 _round,
        address _contributor
    ) public view returns (uint256[] memory fundedAnswers, uint256[] memory contributions) {
        Round storage round = questions[_questionID].rounds[_round];
        fundedAnswers = round.fundedAnswers;
        contributions = new uint256[](round.fundedAnswers.length);
        for (uint256 i = 0; i < contributions.length; i++) {
            contributions[i] = round.contributions[_contributor][fundedAnswers[i]];
        }
    }
    
    /** @dev Returns the sum of withdrawable amount.
     *  @param _questionID The ID of the associated question.
     *  @param _beneficiary The contributor for which to query.
     *  @param _contributedTo Answers that received contributions from contributor.
     *  @return sum The total amount available to withdraw.
     */
    function getTotalWithdrawableAmount(
        uint256 _questionID,
        address payable _beneficiary,
        uint256[] memory _contributedTo
    ) public view override returns (uint256 sum) {
        Question storage question = questions[_questionID];
        if (question.status < Status.Ruled) return sum;
    
        uint256 finalAnswer = question.answer;
        uint256 noOfRounds = question.rounds.length;
        for (uint256 roundNumber = 0; roundNumber < noOfRounds; roundNumber++) {
            for (uint256 contributionNumber = 0; contributionNumber < _contributedTo.length; contributionNumber++) {
                
                Round storage round = question.rounds[roundNumber];
                uint256 answer = _contributedTo[contributionNumber];

                if (!round.hasPaid[answer]) {
                    // Allow to reimburse if funding was unsuccessful for this answer option.
                    sum += round.contributions[_beneficiary][answer];
                } else if (!round.hasPaid[finalAnswer]) {
                    // Reimburse unspent fees proportionally if the ultimate winner didn't pay appeal fees fully.
                    // Note that if only one side is funded it will become a winner and this part of the condition won't be reached.
                    sum += round.fundedAnswers.length > 1
                        ? (round.contributions[_beneficiary][answer] * round.feeRewards) / (round.paidFees[round.fundedAnswers[0]] + round.paidFees[round.fundedAnswers[1]])
                        : 0;
                } else if (finalAnswer == answer) {
                    uint256 paidFees = round.paidFees[answer];
                    // Reward the winner.
                    sum += paidFees > 0 ? (round.contributions[_beneficiary][answer] * round.feeRewards) / paidFees : 0;
                }
            }
        }
        return sum;
    }

    /* Internal */

    /** @dev Execute the ruling of a specified dispute.
     *  @param _questionID The ID of the disputed question.
     *  @param _ruling The ruling given by the ERC792 arbitrator. Note that 0 is reserved for "Refuse to arbitrate".
     */
    function executeRuling(uint256 _questionID, uint256 _ruling) internal {
        Question storage question = questions[_questionID];
        question.answer = _ruling;
        question.status = Status.Ruled;
    }

    /* Private */

    /** @dev Computes the Realitio answerer, of a specified question, that should win. This function is needed to avoid the "stack too deep error".
     *  @param _questionID The ID of the question.
     *  @param _lastAnswerOrCommitmentID The last answer given, or its commitment ID if it was a commitment, to the question in the Realitio contract.
     *  @param _lastBond The bond paid for the last answer to the question in the Realitio contract.
     *  @param _lastAnswerer The last answerer to the question in the Realitio contract.
     *  @param _isCommitment Whether the last answer to the question in the Realitio contract used commit or reveal or not. True if it did, false otherwise.
     *  @return winner The computed winner.
     */
    function computeWinner(
        uint256 _questionID,
        bytes32 _lastAnswerOrCommitmentID,
        uint256 _lastBond,
        address _lastAnswerer,
        bool _isCommitment
    ) private returns (address winner) {
        bytes32 lastAnswer;
        bool isAnswered;
        Question storage question = questions[_questionID];
        if (_lastBond == 0) {
            // If the question hasn't been answered, nobody is ever right.
            isAnswered = false;
        } else if (_isCommitment) {
            (uint32 revealTS, bool isRevealed, bytes32 revealedAnswer) = realitio.commitments(_lastAnswerOrCommitmentID);
            if (isRevealed) {
                lastAnswer = revealedAnswer;
                isAnswered = true;
            } else {
                require(revealTS <= uint32(block.timestamp), "Still has time to reveal.");
                isAnswered = false;
            }
        } else {
            lastAnswer = _lastAnswerOrCommitmentID;
            isAnswered = true;
        }
        return isAnswered && lastAnswer == bytes32(question.answer - 1) ? _lastAnswerer : question.disputer;
    }
}