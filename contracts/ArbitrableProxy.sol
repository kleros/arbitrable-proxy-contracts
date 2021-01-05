// SPDX-License-Identifier: MIT

/**
 *  @authors: [@ferittuncer]
 *  @reviewers: [@fnanni-0*, @unknownunknown1*]
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity >=0.7;

import './IDisputeResolver.sol';
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

/**
 *  @title ArbitrableProxy
 *  A general purpose arbitrable contract. Supports non-binary rulings.
 */
contract ArbitrableProxy is IDisputeResolver {

    using CappedMath for uint; // Operations bounded between 0 and 2**256 - 2. Note the 0 is reserver for invalid / refused to rule.

    uint public constant MAX_NO_OF_CHOICES = (2 ** 256) - 2;

    struct Round {
        mapping(uint => uint) paidFees; // Tracks the fees paid for each ruling option in this round.
        mapping(uint => bool) hasPaid; // True if this ruling option was fully funded; false otherwise.
        mapping(address => mapping(uint => uint)) contributions; // Maps contributors to their contributions for each side.
        uint feeRewards; // Sum of reimbursable appeal fees available to the parties that made contributions to the ruling that ultimately wins a dispute.
        uint[] fundedRulings; // Stores the ruling options that are fully funded.
    }

    struct DisputeStruct {
        bytes arbitratorExtraData;
        bool isRuled;
        uint ruling;
        uint disputeIDOnArbitratorSide;
        uint numberOfChoices;
    }

    address public governor = msg.sender;
    IArbitrator public arbitrator;

    // The required fee stake that a party must pay depends on who won the previous round and is proportional to the arbitration cost such that the fee stake for a round is stake multiplier * arbitration cost for that round.
    uint public winnerStakeMultiplier; // Multiplier of the arbitration cost that the winner has to pay as fee stake for a round in basis points.
    uint public loserStakeMultiplier; // Multiplier of the arbitration cost that the loser has to pay as fee stake for a round in basis points.
    uint public sharedStakeMultiplier; // Multiplier for calculating the fee stake that must be paid in the case where there isn't a winner and loser in basis points.
    uint public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    DisputeStruct[] public disputes;
    mapping(uint => uint) public override externalIDtoLocalID; // Maps external (arbitrator side) dispute ids to local dispute ids.
    mapping(uint => Round[]) public disputeIDtoRoundArray; // Maps dispute ids to round arrays.

    /** @dev Constructor
     *  @param _arbitrator Target global arbitrator for any disputes.
     *  @param _winnerStakeMultiplier Multiplier of the arbitration cost that the winner has to pay as fee stake for a round in basis points.
     *  @param _loserStakeMultiplier Multiplier of the arbitration cost that the loser has to pay as fee stake for a round in basis points.
     *  @param _sharedStakeMultiplier Multiplier for calculating the fee stake that must be paid in the case where there isn't a winner and loser in basis points.
     */
    constructor(IArbitrator _arbitrator, uint _winnerStakeMultiplier, uint _loserStakeMultiplier, uint _sharedStakeMultiplier) {
        arbitrator = _arbitrator;
        winnerStakeMultiplier = _winnerStakeMultiplier;
        loserStakeMultiplier = _loserStakeMultiplier;
        sharedStakeMultiplier = _sharedStakeMultiplier;
    }

    /** @dev TRUSTED. Calls createDispute function of the specified arbitrator to create a dispute.
        Note that we don’t need to check that msg.value is enough to pay arbitration fees as it’s the responsibility of the arbitrator contract.
     *  @param _arbitratorExtraData Extra data for the arbitrator of prospective dispute.
     *  @param _metaevidenceURI Link to metaevidence of prospective dispute.
     *  @param _numberOfChoices Number of ruling options.
     *  @return disputeID Dispute id (on arbitrator side) of the dispute created.
     */
    function createDispute(bytes calldata _arbitratorExtraData, string calldata _metaevidenceURI, uint _numberOfChoices) external payable returns(uint disputeID) {
        if(_numberOfChoices == 0)
            _numberOfChoices = MAX_NO_OF_CHOICES;

        disputeID = arbitrator.createDispute{value: msg.value}(_numberOfChoices, _arbitratorExtraData);

        disputes.push(DisputeStruct({
            arbitratorExtraData: _arbitratorExtraData,
            isRuled: false,
            ruling: 0,
            disputeIDOnArbitratorSide: disputeID,
            numberOfChoices: _numberOfChoices
        }));

        uint localDisputeID = disputes.length - 1;
        externalIDtoLocalID[disputeID] = localDisputeID;

        disputeIDtoRoundArray[localDisputeID].push();

        emit MetaEvidence(localDisputeID, _metaevidenceURI);
        emit Dispute(arbitrator, disputeID, localDisputeID, localDisputeID);
    }

    /** @dev Returns number of possible ruling options. Valid rulings are [0, return value].
     *  @param _localDisputeID Dispute id as in arbitrable contract.
     *  @return count Number of possible ruling options.
     */
    function numberOfRulingOptions(uint _localDisputeID) external view override returns (uint count){
        count = disputes[_localDisputeID].numberOfChoices;
    }

    /** @dev TRUSTED. Manages contributions and calls appeal function of the specified arbitrator to appeal a dispute. This function lets appeals be crowdfunded.
        Note that we don’t need to check that msg.value is enough to pay arbitration fees as it’s the responsibility of the arbitrator contract.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _ruling The ruling to which the caller wants to contribute.
     *  @return fullyFunded Whether _ruling was fully funded after the call.
     */
    function fundAppeal(uint _localDisputeID, uint _ruling) external override payable returns (bool fullyFunded){
        DisputeStruct storage dispute = disputes[_localDisputeID];
        require(_ruling <= dispute.numberOfChoices, "There is no such ruling to fund.");

        (uint appealPeriodStart, uint appealPeriodEnd) = appealPeriod(_localDisputeID, _ruling);
        require(block.timestamp >= appealPeriodStart && block.timestamp < appealPeriodEnd, "Funding must be made within the appeal period.");

        uint totalCost = appealCost(_localDisputeID, _ruling);

        Round[] storage rounds = disputeIDtoRoundArray[_localDisputeID];
        Round storage lastRound = rounds[rounds.length - 1];
        require(!lastRound.hasPaid[_ruling], "Appeal fee has already been paid.");
        require(msg.value > 0, "Can't contribute zero");

        uint contribution = totalCost.subCap(lastRound.paidFees[_ruling]) > msg.value ? msg.value : totalCost.subCap(lastRound.paidFees[_ruling]);
        emit Contribution(_localDisputeID, rounds.length - 1, _ruling, msg.sender, contribution);

        lastRound.contributions[msg.sender][_ruling] += contribution;
        lastRound.paidFees[_ruling] += contribution;

        if (lastRound.paidFees[_ruling] >= totalCost) {
            lastRound.feeRewards += lastRound.paidFees[_ruling];
            lastRound.fundedRulings.push(_ruling);
            lastRound.hasPaid[_ruling] = true;
            emit RulingFunded(_localDisputeID, rounds.length - 1, _ruling);
        }

        uint appealFee = arbitrator.appealCost(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);

        if (lastRound.fundedRulings.length > 1) {
            // At least two sides are fully funded.
            rounds.push();

            lastRound.feeRewards = lastRound.feeRewards.subCap(appealFee);
            arbitrator.appeal{value: appealFee}(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);
        }

        msg.sender.transfer(msg.value.subCap(contribution)); // Sending extra value back to contributor.

        return lastRound.hasPaid[_ruling];
    }

    /** @dev Retrieves appeal period for each ruling. It extends the function with the same name on the arbitrator side by adding
     *  _ruling parameter because in practice we don't give losers of previous round as much time as the winner.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _ruling The ruling option which the caller wants to learn about its appeal period.
     */
    function appealPeriod(uint _localDisputeID, uint _ruling) public override view returns (uint start, uint end){
        DisputeStruct storage dispute = disputes[_localDisputeID];

        uint winner = arbitrator.currentRuling(dispute.disputeIDOnArbitratorSide);

        (uint originalStart, uint originalEnd) = arbitrator.appealPeriod(dispute.disputeIDOnArbitratorSide);

        if(winner == _ruling) return (originalStart, originalEnd);
        else return (originalStart, (originalStart + originalEnd)/2);
    }


    /** @dev Retrieves appeal cost for each ruling. It extends the function with the same name on the arbitrator side by adding
     *  _ruling parameter because total to be raised depends on multipliers.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _ruling The ruling option which the caller wants to learn about its appeal cost.
     */
    function appealCost(uint _localDisputeID, uint _ruling) public override view returns (uint){
        DisputeStruct storage dispute = disputes[_localDisputeID];

        uint winner = arbitrator.currentRuling(dispute.disputeIDOnArbitratorSide);
        uint multiplier;

        if (winner == _ruling){
            multiplier = winnerStakeMultiplier;
        } else if (winner == 0){
            multiplier = sharedStakeMultiplier;
        } else {
            multiplier = loserStakeMultiplier;
        }

        uint appealFee = arbitrator.appealCost(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);
        return appealFee.addCap(appealFee.mulCap(multiplier) / MULTIPLIER_DIVISOR);
    }


    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _roundNumber The number of the round caller wants to withdraw from.
     *  @param _ruling The ruling option that the caller wants to withdraw fees and rewards related to it.
     *  @return sum Reward amount that is to be withdrawn. Might be zero if arguments are not qualifying for a reward or reimbursement, or it might be withdrawn already.
     */
    function withdrawFeesAndRewards(uint _localDisputeID, address payable _contributor, uint _roundNumber, uint _ruling) public override returns (uint sum) {
        DisputeStruct storage dispute = disputes[_localDisputeID];

        Round storage round = disputeIDtoRoundArray[_localDisputeID][_roundNumber];
        uint finalRuling = dispute.ruling;

        require(dispute.isRuled, "The dispute should be solved");

        if (!round.hasPaid[_ruling]) {
            // Allow to reimburse if funding was unsuccessful.
            sum = round.contributions[_contributor][_ruling];

        } else if (finalRuling == 0 || !round.hasPaid[finalRuling]) {
            // Reimburse unspent fees proportionally if there is no winner and loser.
            sum = round.fundedRulings.length > 1 // Means appeal took place.
                ? (round.contributions[_contributor][_ruling] * round.feeRewards) / (round.paidFees[round.fundedRulings[0]] + round.paidFees[round.fundedRulings[1]])
                : 0;
        } else if(_ruling == finalRuling) {
            // Reward the winner.
            sum = round.paidFees[_ruling] > 0
                ? (round.contributions[_contributor][_ruling] * round.feeRewards) / round.paidFees[_ruling]
                : 0;
        }

        if(sum != 0) {
            round.contributions[_contributor][_ruling] = 0;
            _contributor.send(sum); // User is responsible for accepting the reward.
            emit Withdrawal(_localDisputeID, _roundNumber, _ruling, _contributor, sum);
        }
    }

    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved for multiple ruling options at once.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _roundNumber The number of the round caller wants to withdraw from.
     *  @param _contributedTo Rulings that received contributions from contributor.
     */
    function withdrawFeesAndRewardsForMultipleRulings(uint _localDisputeID, address payable _contributor, uint _roundNumber, uint[] memory _contributedTo) public override {
        for (uint contributionNumber = 0; contributionNumber < _contributedTo.length; contributionNumber++) {
            withdrawFeesAndRewards(_localDisputeID, _contributor, _roundNumber, _contributedTo[contributionNumber]);
        }
    }

    /** @dev Allows to withdraw any rewards or reimbursable fees after the dispute gets resolved. For multiple rulings options and for all rounds at once.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _contributedTo Rulings that received contributions from contributor.
     */
    function withdrawFeesAndRewardsForAllRounds(uint _localDisputeID, address payable _contributor, uint[] memory _contributedTo) external override {
      uint noOfRounds = disputeIDtoRoundArray[_localDisputeID].length;
        for (uint roundNumber = 0; roundNumber < noOfRounds; roundNumber++) {
            withdrawFeesAndRewardsForMultipleRulings(_localDisputeID, _contributor, roundNumber, _contributedTo);
        }
    }

    /** @dev Returns the sum of withdrawable amount. Although it's a nested loop, total iterations will be almost always less than 10. (Max number of rounds is 7 and it's very unlikely to have a contributor to contribute to more than 1 ruling option per round). Alternatively you can use Contribution events to calculate this off-chain.
     *  @param _localDisputeID The ID of the associated question.
     *  @param _contributor The contributor for which to query.
     *  @param _contributedTo The array which includes ruling options to search for potential withdrawal. Caller can obtain this information using Contribution events.
     *  @return sum The total amount available to withdraw.
     */
    function getTotalWithdrawableAmount(uint _localDisputeID, address payable _contributor, uint[] memory _contributedTo) public override view returns (uint sum) {
      uint noOfRounds = disputeIDtoRoundArray[_localDisputeID].length;
      for (uint roundNumber = 0; roundNumber < noOfRounds; roundNumber++) {
        for (uint contributionNumber = 0; contributionNumber < _contributedTo.length; contributionNumber++) {

          DisputeStruct storage dispute = disputes[_localDisputeID];

          Round storage round = disputeIDtoRoundArray[_localDisputeID][roundNumber];
          uint finalRuling = dispute.ruling;
          uint ruling = _contributedTo[contributionNumber];
          require(dispute.isRuled, "The dispute should be solved");

          if (!round.hasPaid[ruling]) {
              // Allow to reimburse if funding was unsuccessful.
              sum = round.contributions[_contributor][ruling];

          } else if (finalRuling == 0 || !round.hasPaid[finalRuling]) {
              // Reimburse unspent fees proportionally if there is no winner and loser.
              sum = round.fundedRulings.length > 1 // Means appeal took place.
                  ? (round.contributions[_contributor][ruling] * round.feeRewards) / (round.paidFees[round.fundedRulings[0]] + round.paidFees[round.fundedRulings[1]])
                  : 0;
          } else if(ruling == finalRuling) {
              // Reward the winner.
              sum = round.paidFees[ruling] > 0
                  ? (round.contributions[_contributor][ruling] * round.feeRewards) / round.paidFees[ruling]
                  : 0;
          }

        }
      }
      return sum;
    }

    /** @dev To be called by the arbitrator of the dispute, to declare winning ruling.
     *  @param _externalDisputeID ID of the dispute in arbitrator contract.
     *  @param _ruling The ruling choice of the arbitration.
     */
    function rule(uint _externalDisputeID, uint _ruling) external override {
        uint _localDisputeID = externalIDtoLocalID[_externalDisputeID];
        DisputeStruct storage dispute = disputes[_localDisputeID];
        require(msg.sender == address(arbitrator), "Only the arbitrator can execute this.");
        require(_ruling <= dispute.numberOfChoices, "Invalid ruling.");
        require(dispute.isRuled == false, "This dispute has been ruled already.");

        dispute.isRuled = true;
        dispute.ruling = _ruling;

        Round[] storage rounds = disputeIDtoRoundArray[_localDisputeID];
        Round storage lastRound = disputeIDtoRoundArray[_localDisputeID][rounds.length - 1];
        // If only one ruling option is funded, it wins by default. Note that if any other ruling had funded, an appeal would have been created.
        if (lastRound.fundedRulings.length == 1) {
            dispute.ruling = lastRound.fundedRulings[0];
        }

        emit Ruling(IArbitrator(msg.sender), _externalDisputeID, uint(dispute.ruling));
    }

    /** @dev Allows to submit evidence for a given dispute.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _evidenceURI Link to evidence.
     */
    function submitEvidence(uint _localDisputeID, string calldata _evidenceURI) external override {
        DisputeStruct storage dispute = disputes[_localDisputeID];
        require(dispute.isRuled == false, "Cannot submit evidence to a resolved dispute.");

        emit Evidence(arbitrator, _localDisputeID, msg.sender, _evidenceURI);
    }

    /** @dev Changes the proportion of appeal fees that must be paid when there is no winner or loser.
     *  @param _sharedStakeMultiplier The new tie multiplier value respect to MULTIPLIER_DIVISOR.
     */
    function changeSharedStakeMultiplier(uint _sharedStakeMultiplier) external {
        require(msg.sender == governor, "Only the governor can execute this.");
        sharedStakeMultiplier = _sharedStakeMultiplier;
    }

    /** @dev Changes the proportion of appeal fees that must be paid by winner.
     *  @param _winnerStakeMultiplier The new winner multiplier value respect to MULTIPLIER_DIVISOR.
     */
    function changeWinnerStakeMultiplier(uint _winnerStakeMultiplier) external {
        require(msg.sender == governor, "Only the governor can execute this.");
        winnerStakeMultiplier = _winnerStakeMultiplier;
    }

    /** @dev Changes the proportion of appeal fees that must be paid by loser.
     *  @param _loserStakeMultiplier The new loser multiplier value respect to MULTIPLIER_DIVISOR.
     */
    function changeLoserStakeMultiplier(uint _loserStakeMultiplier) external {
        require(msg.sender == governor, "Only the governor can execute this.");
        loserStakeMultiplier = _loserStakeMultiplier;
    }

    /** @dev Returns stake multipliers.
     *  @return winner Winners stake multiplier.
     *  @return loser Losers stake multiplier.
     *  @return shared Multiplier when it's tied.
     *  @return divisor Multiplier divisor.
     */
    function getMultipliers() external override view returns(uint winner, uint loser, uint shared, uint divisor){
      return (winnerStakeMultiplier, loserStakeMultiplier, sharedStakeMultiplier, MULTIPLIER_DIVISOR);
    }

    /** @dev Gets the information of a round of a dispute.
     *  @param _localDisputeID ID of the dispute.
     *  @param _round The round to be queried.
     */
    function getRoundInfo(uint _localDisputeID, uint _round) external view
    returns (
        uint[] memory paidFees,
        uint feeRewards,
        uint[] memory fundedRulings
    )
    {
        Round storage round = disputeIDtoRoundArray[_localDisputeID][_round];
        fundedRulings = round.fundedRulings;

        paidFees = new uint[](round.fundedRulings.length);

        for (uint i = 0; i < round.fundedRulings.length; i++) {
            paidFees[i] = round.paidFees[round.fundedRulings[i]];
        }

        feeRewards = round.feeRewards;
    }

    /** @dev Gets the information of a round of a dispute for a specific ruling option.
     *  @param _localDisputeID ID of the dispute.
     *  @param _round The round to be queried.
     *  @param _rulingOption The ruling option to get funding status.
     */
    function getFundingStatus(uint _localDisputeID, uint _round, uint _rulingOption) external view returns(uint raised, bool fullyFunded)
    {
        Round storage round = disputeIDtoRoundArray[_localDisputeID][_round];

        raised = round.paidFees[_rulingOption];
        fullyFunded = round.hasPaid[_rulingOption];
    }

    /** @dev Gets contributions to ruling options that are fully funded.
     *  @param _localDisputeID ID of the dispute.
     *  @param _round The round to be queried.
     *  @param _contributor The address this function queries contributions of.
     */
    function getContributionsToSuccessfulFundings(
    uint _localDisputeID,
    uint _round,
    address _contributor
    ) public view returns(
        uint[] memory fundedRulings,
        uint[] memory contributions
        )
    {
        Round storage round = disputeIDtoRoundArray[_localDisputeID][_round];
        fundedRulings = round.fundedRulings;
        contributions = new uint[](round.fundedRulings.length);
        for (uint i = 0; i < contributions.length; i++) {
            contributions[i] = round.contributions[_contributor][fundedRulings[i]];
        }
    }

    /** @dev Returns active disputes.
     *  @param _cursor Starting point for search.
     *  @param _count Number of items to return.
     *  @return openDisputes Dispute identifiers of open disputes, as in arbitrator.
     *  @return hasMore Whether the search was exhausted (has no more) or not (has more).
     */
    function getOpenDisputes(uint _cursor, uint _count) external view returns (uint[] memory openDisputes, bool hasMore)
    {
        uint noOfOpenDisputes = 0;
        uint i;
        for (i = _cursor; i < disputes.length && (noOfOpenDisputes < _count || _count == 0); i++) {
            if(disputes[i].isRuled == false){
                noOfOpenDisputes++;
            }
        }
        openDisputes = new uint[](noOfOpenDisputes);

        uint count = 0;
        hasMore = true;
        for (i = _cursor; i < disputes.length && (count < _count || _count == 0); i++) {
            if(disputes[i].isRuled == false){
                openDisputes[count++] = disputes[i].disputeIDOnArbitratorSide;
            }
        }

        if(i == disputes.length) hasMore = false;
    }
}
