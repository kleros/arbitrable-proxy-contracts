// SPDX-License-Identifier: MIT

/**
 *  @authors: [@ferittuncer]
 *  @reviewers: [@remedcu]
 *  @auditors: []
 *  @bounties: []
 *  @deployments: [0xeF6F9665B3aAC2894Ea4c458F93aBA5BB8f8b86d, 0xc7e49251807780dFBbCA72778890B80bd946590B]
 */

pragma solidity >=0.7;

import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

/**
 *  @title BinaryArbitrableProxy
 *  This contract acts as a general purpose dispute creator.
 */
contract BinaryArbitrableProxy is IArbitrable, IEvidence {
    using CappedMath for uint256; // Operations bounded between 0 and 2**256 - 1.
    address public governor = msg.sender;
    IArbitrator public arbitrator;

    // The required fee stake that a party must pay depends on who won the previous round and is proportional to the arbitration cost such that the fee stake for a round is stake multiplier * arbitration cost for that round.
    // Multipliers are in basis points.
    uint256 public winnerStakeMultiplier; // Multiplier for calculating the fee stake paid by the party that won the previous round.
    uint256 public loserStakeMultiplier; // Multiplier for calculating the fee stake paid by the party that lost the previous round.
    uint256 public sharedStakeMultiplier; // Multiplier for calculating the fee stake that must be paid in the case where there isn't a winner and loser (e.g. when it's the first round or the arbitrator ruled "refused to rule"/"could not rule").
    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    uint256 constant NUMBER_OF_CHOICES = 2;
    enum Party {None, Requester, Respondent}

    /** @dev Constructor
     *  @param _arbitrator Target global arbitrator for any disputes.
     *  @param _winnerStakeMultiplier Multiplier of the arbitration cost that the winner has to pay as fee stake for a round in basis points.
     *  @param _loserStakeMultiplier Multiplier of the arbitration cost that the loser has to pay as fee stake for a round in basis points.
     *  @param _sharedStakeMultiplier Multiplier of the arbitration cost that each party must pay as fee stake for a round when there isn't a winner/loser in the previous round (e.g. when it's the first round or the arbitrator refused to or did not rule). In basis points.
     */
    constructor(
        IArbitrator _arbitrator,
        uint256 _winnerStakeMultiplier,
        uint256 _loserStakeMultiplier,
        uint256 _sharedStakeMultiplier
    ) public {
        arbitrator = _arbitrator;
        winnerStakeMultiplier = _winnerStakeMultiplier;
        loserStakeMultiplier = _loserStakeMultiplier;
        sharedStakeMultiplier = _sharedStakeMultiplier;
    }

    struct Round {
        uint256[3] paidFees; // Tracks the fees paid by each side in this round.
        bool[3] hasPaid; // True when the side has fully paid its fee. False otherwise.
        uint256 feeRewards; // Sum of reimbursable appeal fees available to the parties that made contributions to the side that ultimately wins a dispute.
        mapping(address => uint256[3]) contributions; // Maps contributors to their contributions for each side.
    }

    struct DisputeStruct {
        bytes arbitratorExtraData;
        bool isRuled;
        Party ruling;
        uint256 disputeIDOnArbitratorSide;
    }

    DisputeStruct[] public disputes;
    mapping(uint256 => uint256) public externalIDtoLocalID;
    mapping(uint256 => Round[]) public disputeIDRoundIDtoRound;
    mapping(uint256 => mapping(address => bool)) public withdrewAlready;

    /** @dev TRUSTED. Calls createDispute function of the specified arbitrator to create a dispute.
        Note that we don’t need to check that msg.value is enough to pay arbitration fees as it’s the responsibility of the arbitrator contract.
     *  @param _arbitratorExtraData Extra data for the arbitrator of prospective dispute.
     *  @param _metaevidenceURI Link to metaevidence of prospective dispute.
     */
    function createDispute(bytes calldata _arbitratorExtraData, string calldata _metaevidenceURI) external payable returns (uint256 disputeID) {
        disputeID = arbitrator.createDispute{value: msg.value}(NUMBER_OF_CHOICES, _arbitratorExtraData);

        disputes.push(DisputeStruct({arbitratorExtraData: _arbitratorExtraData, isRuled: false, ruling: Party.None, disputeIDOnArbitratorSide: disputeID}));

        uint256 localDisputeID = disputes.length - 1;
        externalIDtoLocalID[disputeID] = localDisputeID;

        disputeIDRoundIDtoRound[localDisputeID].push();

        emit MetaEvidence(localDisputeID, _metaevidenceURI);
        emit Dispute(arbitrator, disputeID, localDisputeID, localDisputeID);
    }

    /** @dev Returns the contribution value and remainder from available ETH and required amount.
     *  @param _available The amount of ETH available for the contribution.
     *  @param _requiredAmount The amount of ETH required for the contribution.
     *  @return taken The amount of ETH taken.
     *  @return remainder The amount of ETH left from the contribution.
     */
    function calculateContribution(uint256 _available, uint256 _requiredAmount) internal pure returns (uint256 taken, uint256 remainder) {
        if (_requiredAmount > _available) return (_available, 0); // Take whatever is available, return 0 as leftover ETH.

        remainder = _available - _requiredAmount;
        return (_requiredAmount, remainder);
    }

    /** @dev Make a fee contribution.
     *  @param _round The round to contribute.
     *  @param _side The side for which to contribute.
     *  @param _contributor The contributor.
     *  @param _amount The amount contributed.
     *  @param _totalRequired The total amount required for this side.
     */
    function contribute(
        Round storage _round,
        Party _side,
        address payable _contributor,
        uint256 _amount,
        uint256 _totalRequired
    ) internal {
        // Take up to the amount necessary to fund the current round at the current costs.
        uint256 contribution; // Amount contributed.
        uint256 remainingETH; // Remaining ETH to send back.
        (contribution, remainingETH) = calculateContribution(_amount, _totalRequired.subCap(_round.paidFees[uint256(_side)]));
        _round.contributions[_contributor][uint256(_side)] += contribution;
        _round.paidFees[uint256(_side)] += contribution;
        _round.feeRewards += contribution;

        // Reimburse leftover ETH.
        _contributor.send(remainingETH); // Deliberate use of send in order to not block the contract in case of reverting fallback.
    }

    /** @dev TRUSTED. Manages contributions and calls appeal function of the specified arbitrator to appeal a dispute. This function lets appeals be crowdfunded.
        Note that we don’t need to check that msg.value is enough to pay arbitration fees as it’s the responsibility of the arbitrator contract.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _side The side to which the caller wants to contribute.
     */
    function fundAppeal(uint256 _localDisputeID, Party _side) external payable {
        require(_side != Party.None, "You can't fund an appeal in favor of refusing to arbitrate.");
        DisputeStruct storage dispute = disputes[_localDisputeID];

        (uint256 appealPeriodStart, uint256 appealPeriodEnd) = arbitrator.appealPeriod(dispute.disputeIDOnArbitratorSide);
        require(block.timestamp >= appealPeriodStart && block.timestamp < appealPeriodEnd, "Funding must be made within the appeal period.");

        Party winner = Party(arbitrator.currentRuling(dispute.disputeIDOnArbitratorSide));
        Party loser;
        if (winner == Party.Requester) loser = Party.Respondent;
        else if (winner == Party.Respondent) loser = Party.Requester;
        require(!(_side == loser) || (block.timestamp - appealPeriodStart < (appealPeriodEnd - appealPeriodStart) / 2), "The loser must contribute during the first half of the appeal period.");

        uint256 multiplier;
        if (_side == winner) {
            multiplier = winnerStakeMultiplier;
        } else if (_side == loser) {
            multiplier = loserStakeMultiplier;
        } else {
            multiplier = sharedStakeMultiplier;
        }

        uint256 appealCost = arbitrator.appealCost(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);
        uint256 totalCost = appealCost.addCap(appealCost.mulCap(multiplier) / MULTIPLIER_DIVISOR);

        Round[] storage rounds = disputeIDRoundIDtoRound[_localDisputeID];
        Round storage lastRound = disputeIDRoundIDtoRound[_localDisputeID][rounds.length - 1];

        contribute(lastRound, _side, msg.sender, msg.value, totalCost);

        if (lastRound.paidFees[uint256(_side)] >= totalCost) lastRound.hasPaid[uint256(_side)] = true;

        if (lastRound.hasPaid[uint8(Party.Requester)] && lastRound.hasPaid[uint8(Party.Respondent)]) {
            rounds.push();
            lastRound.feeRewards = lastRound.feeRewards.subCap(appealCost);
            arbitrator.appeal{value: appealCost}(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);
        }
    }

    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _roundNumber The number of the round caller wants to withdraw from.
     */
    function withdrawFeesAndRewards(
        uint256 _localDisputeID,
        address payable _contributor,
        uint256 _roundNumber
    ) public {
        DisputeStruct storage dispute = disputes[_localDisputeID];

        Round storage round = disputeIDRoundIDtoRound[_localDisputeID][_roundNumber];
        uint8 ruling = uint8(dispute.ruling);

        require(dispute.isRuled, "The dispute should be solved");
        uint256 reward;
        if (!round.hasPaid[uint8(Party.Requester)] || !round.hasPaid[uint8(Party.Respondent)]) {
            // Allow to reimburse if funding was unsuccessful.
            reward = round.contributions[_contributor][uint8(Party.Requester)] + round.contributions[_contributor][uint8(Party.Respondent)];
            round.contributions[_contributor][uint8(Party.Requester)] = 0;
            round.contributions[_contributor][uint8(Party.Respondent)] = 0;
        } else if (Party(ruling) == Party.None) {
            // Reimburse unspent fees proportionally if there is no winner and loser.
            uint256 rewardRequester = round.paidFees[uint8(Party.Requester)] > 0 ? (round.contributions[_contributor][uint8(Party.Requester)] * round.feeRewards) / (round.paidFees[uint8(Party.Requester)] + round.paidFees[uint8(Party.Respondent)]) : 0;
            uint256 rewardRespondent = round.paidFees[uint8(Party.Respondent)] > 0 ? (round.contributions[_contributor][uint8(Party.Respondent)] * round.feeRewards) / (round.paidFees[uint8(Party.Requester)] + round.paidFees[uint8(Party.Respondent)]) : 0;

            reward = rewardRequester + rewardRespondent;
            round.contributions[_contributor][uint8(Party.Requester)] = 0;
            round.contributions[_contributor][uint8(Party.Respondent)] = 0;
        } else {
            // Reward the winner.
            reward = round.paidFees[ruling] > 0 ? (round.contributions[_contributor][ruling] * round.feeRewards) / round.paidFees[ruling] : 0;
            round.contributions[_contributor][ruling] = 0;
        }

        _contributor.send(reward); // User is responsible for accepting the reward.
    }

    /** @dev Allows to withdraw any rewards or reimbursable fees after the dispute gets resolved, for all rounds.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     */
    function withdrawFeesAndRewardsForAllRounds(uint256 _localDisputeID, address payable _contributor) external {
        require(withdrewAlready[_localDisputeID][_contributor] == false, "This contributor withdrew all already.");
        for (uint256 roundNumber = 0; roundNumber < disputeIDRoundIDtoRound[_localDisputeID].length; roundNumber++) {
            withdrawFeesAndRewards(_localDisputeID, _contributor, roundNumber);
        }

        withdrewAlready[_localDisputeID][_contributor] = true;
    }

    /** @dev To be called by the arbitrator of the dispute, to declare winning side.
     *  @param _externalDisputeID ID of the dispute in arbitrator contract.
     *  @param _ruling The ruling choice of the arbitration.
     */
    function rule(uint256 _externalDisputeID, uint256 _ruling) external override {
        uint256 _localDisputeID = externalIDtoLocalID[_externalDisputeID];
        DisputeStruct storage dispute = disputes[_localDisputeID];
        require(msg.sender == address(arbitrator), "Only the arbitrator can execute this.");
        require(_ruling <= NUMBER_OF_CHOICES, "Invalid ruling.");
        require(dispute.isRuled == false, "Is ruled already.");

        dispute.isRuled = true;
        dispute.ruling = Party(_ruling);

        Round[] storage rounds = disputeIDRoundIDtoRound[_localDisputeID];
        Round storage round = disputeIDRoundIDtoRound[_localDisputeID][rounds.length - 1];

        if (round.hasPaid[uint8(Party.Requester)] == true)
            // If one side paid its fees, the ruling is in its favor. Note that if the other side had also paid, an appeal would have been created.
            dispute.ruling = Party.Requester;
        else if (round.hasPaid[uint8(Party.Respondent)] == true) dispute.ruling = Party.Respondent;

        emit Ruling(IArbitrator(msg.sender), _externalDisputeID, uint256(dispute.ruling));
    }

    /** @dev Allows to submit evidence for a given dispute.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _evidenceURI Link to evidence.
     */
    function submitEvidence(uint256 _localDisputeID, string calldata _evidenceURI) external {
        DisputeStruct storage dispute = disputes[_localDisputeID];
        require(dispute.isRuled == false, "Cannot submit evidence to a resolved dispute.");

        emit Evidence(arbitrator, _localDisputeID, msg.sender, _evidenceURI);
    }

    /** @dev Changes the proportion of appeal fees that must be paid when there is no winner or loser.
     *  @param _sharedStakeMultiplier The new tie multiplier value respect to MULTIPLIER_DIVISOR.
     */
    function changeSharedStakeMultiplier(uint256 _sharedStakeMultiplier) external {
        require(msg.sender == governor, "Only the governor can execute this.");
        sharedStakeMultiplier = _sharedStakeMultiplier;
    }

    /** @dev Changes the proportion of appeal fees that must be paid by winner.
     *  @param _winnerStakeMultiplier The new winner multiplier value respect to MULTIPLIER_DIVISOR.
     */
    function changeWinnerStakeMultiplier(uint256 _winnerStakeMultiplier) external {
        require(msg.sender == governor, "Only the governor can execute this.");
        winnerStakeMultiplier = _winnerStakeMultiplier;
    }

    /** @dev Changes the proportion of appeal fees that must be paid by loser.
     *  @param _loserStakeMultiplier The new loser multiplier value respect to MULTIPLIER_DIVISOR.
     */
    function changeLoserStakeMultiplier(uint256 _loserStakeMultiplier) external {
        require(msg.sender == governor, "Only the governor can execute this.");
        loserStakeMultiplier = _loserStakeMultiplier;
    }

    /** @dev Gets the information of a round of a dispute.
     *  @param _localDisputeID ID of the dispute.
     *  @param _round The round to be queried.
     *  @return appealed Whether the round is appealed or not.
     *  @return paidFees Total fees paid for each party.
     *  @return hasPaid Whether given party paid required amount or not, for each party.
     *  @return feeRewards Total fees collected for parties excluding appeal cost.
     */
    function getRoundInfo(uint256 _localDisputeID, uint256 _round)
        external
        view
        returns (
            bool appealed,
            uint256[3] memory paidFees,
            bool[3] memory hasPaid,
            uint256 feeRewards
        )
    {
        Round storage round = disputeIDRoundIDtoRound[_localDisputeID][_round];
        return (_round != (disputeIDRoundIDtoRound[_localDisputeID].length - 1), round.paidFees, round.hasPaid, round.feeRewards);
    }

    /** @dev Returns stake multipliers.
     *  @return winner Winners stake multiplier.
     *  @return loser Losers stake multiplier.
     *  @return shared Multiplier when it's tied.
     *  @return divisor Multiplier divisor.
     */
    function getMultipliers()
        external
        view
        returns (
            uint256 winner,
            uint256 loser,
            uint256 shared,
            uint256 divisor
        )
    {
        return (winnerStakeMultiplier, loserStakeMultiplier, sharedStakeMultiplier, MULTIPLIER_DIVISOR);
    }

    /** @dev Returns crowdfunding status, useful for user interfaces.
     *  @param _localDisputeID Dispute ID as in this contract.
     *  @param _participant Address of crowdfunding participant to get details of.
     *  @return paidFees Total fees paid for each party in the last round.
     *  @return hasPaid Whether given party paid required amount or not, for each party, in the last round.
     *  @return feeRewards Total fees collected for parties excluding appeal cost, in the last round.
     * @return contributions Contributions of given participant in the last round.
     */
    function crowdfundingStatus(uint256 _localDisputeID, address _participant)
        external
        view
        returns (
            uint256[3] memory paidFees,
            bool[3] memory hasPaid,
            uint256 feeRewards,
            uint256[3] memory contributions
        )
    {
        Round[] storage rounds = disputeIDRoundIDtoRound[_localDisputeID];
        Round storage round = disputeIDRoundIDtoRound[_localDisputeID][rounds.length - 1];

        return (round.paidFees, round.hasPaid, round.feeRewards, round.contributions[_participant]);
    }

    /** @dev Proxy getter for arbitration cost.
     *  @param  _arbitratorExtraData Extra data for arbitration cost calculation. See arbitrator for details.
     *  @return arbitrationFee Arbitration cost of the arbitrator of this contract.
     */
    function getArbitrationCost(bytes calldata _arbitratorExtraData) external view returns (uint256 arbitrationFee) {
        arbitrationFee = arbitrator.arbitrationCost(_arbitratorExtraData);
    }

    /** @dev Returns active disputes.
     *  @param _cursor Starting point for search.
     *  @param _count Number of items to return.
     *  @return openDisputes Dispute identifiers of open disputes, as in arbitrator.
     *  @return hasMore Whether the search was exhausted (has no more) or not (has more).
     */
    function getOpenDisputes(uint256 _cursor, uint256 _count) external view returns (uint256[] memory openDisputes, bool hasMore) {
        uint256 noOfOpenDisputes = 0;
        for (uint256 i = 0; i < disputes.length; i++) {
            if (disputes[i].isRuled == false) {
                noOfOpenDisputes++;
            }
        }
        openDisputes = new uint256[](noOfOpenDisputes);

        uint256 count = 0;
        hasMore = true;
        uint256 i;
        for (i = _cursor; i < disputes.length && (count < _count || 0 == _count); i++) {
            if (disputes[i].isRuled == false) {
                openDisputes[count++] = disputes[i].disputeIDOnArbitratorSide;
            }
        }

        if (i == disputes.length) hasMore = false;
    }
}
