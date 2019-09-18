/**
 *  @authors: [@ferittuncer]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity >=0.5 <0.6.0;

import "../node_modules/@kleros/erc-792/contracts/IArbitrable.sol";
import "../node_modules/@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "../node_modules/@kleros/erc-792/contracts/Arbitrator.sol";
import "../node_modules/@kleros/ethereum-libraries/contracts/CappedMath.sol";

/**
 *  @title BinaryArbitrableProxy
 *  This contract acts as a general purpose dispute creator.
 */
contract BinaryArbitrableProxy is IArbitrable, IEvidence {

    using CappedMath for uint;

    uint constant NUMBER_OF_CHOICES = 2;

    struct Round {
      uint[3] paidFees; // Tracks the fees paid by each side in this round.
      bool[3] hasPaid; // True when the side has fully paid its fee. False otherwise.
      uint totalAppealFeesCollected; // Sum of reimbursable appeal fees available to the parties that made contributions to the side that ultimately wins a dispute.
      mapping(address => uint[3]) contributions; // Maps contributors to their contributions for each side.
    }

    struct DisputeStruct {
        Arbitrator arbitrator;
        bytes arbitratorExtraData;
        bool isRuled;
        uint disputeIDOnArbitratorSide;
        Round[] rounds;
    }

    DisputeStruct[] public disputes;

    /** @dev Calls createDispute function of the specified arbitrator to create a dispute.
     *  @param _arbitrator The arbitrator of prospective dispute.
     *  @param _arbitratorExtraData Extra data for the arbitrator of prospective dispute.
     *  @param _metaevidenceURI Link to metaevidence of prospective dispute.
     */
    function createDispute(Arbitrator _arbitrator, bytes calldata _arbitratorExtraData, string calldata _metaevidenceURI) external payable {
        uint arbitrationCost = _arbitrator.arbitrationCost(_arbitratorExtraData);
        uint _disputeIDOnArbitratorSide = _arbitrator.createDispute.value(arbitrationCost)(NUMBER_OF_CHOICES, _arbitratorExtraData);

        uint disputeID = disputes.length++;
        DisputeStruct storage dispute = disputes[disputeID];
        dispute.arbitrator = _arbitrator;
        dispute.arbitratorExtraData = _arbitratorExtraData;
        dispute.disputeIDOnArbitratorSide = _disputeIDOnArbitratorSide;
        dispute.rounds.length++;

        emit MetaEvidence(disputes.length-1, _metaevidenceURI);
    }

    /** @dev Manages contributions and calls appeal function of the specified arbitrator to appeal a dispute. This function lets appeals to be crowdfunded.
     *  @param _localDisputeID Index of the dispute on disputes array.
     *  @param _side The side which the caller wants to contribute.
     */
    function appeal(uint _localDisputeID, uint _side) external payable {
        require(_localDisputeID < disputes.length, "Dispute id out of bounds.");
        DisputeStruct storage dispute = disputes[_localDisputeID];

        (uint appealPeriodStart, uint appealPeriodEnd) = dispute.arbitrator.appealPeriod(dispute.disputeIDOnArbitratorSide);
        require(now >= appealPeriodStart && now < appealPeriodEnd, "Funding must be made within the appeal period.");

        Round storage round = dispute.rounds[dispute.rounds.length-1];

        require(!round.hasPaid[_side], "Appeal fee has already been paid");

        uint appealCost = dispute.arbitrator.appealCost(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);

        uint contribution;

        if(round.paidFees[_side] + msg.value >= appealCost){
          contribution = appealCost - round.paidFees[_side];
          round.hasPaid[_side] = true;
        }
        else
            contribution = msg.value;

        msg.sender.send(msg.value - contribution);
        round.contributions[msg.sender][_side] = contribution;
        round.paidFees[_side] += contribution;
        round.totalAppealFeesCollected += contribution;

        if(round.hasPaid[1] && round.hasPaid[2]){
            dispute.arbitrator.appeal.value(appealCost)(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);
            dispute.rounds.length++;
            round.totalAppealFeesCollected = round.totalAppealFeesCollected.subCap(appealCost);
        }
    }

    /** @dev Lets to withdraw any reimbursable fees or rewards after the dispute gets solved.
     *  @param _localDisputeID Index of the dispute on disputes array.
     *  @param _contributor The side which the caller wants to contribute.
     *  @param _roundNumber The number of the round caller wants to withdraw of.
     */
    function withdrawFeesAndRewards(uint _localDisputeID, address payable _contributor, uint _roundNumber) external {
        require(_localDisputeID < disputes.length, "Dispute id out of bounds.");
        require(_roundNumber < disputes[_localDisputeID].rounds.length, "Round number out of bounds.");

        DisputeStruct storage dispute = disputes[_localDisputeID];
        Round storage round = dispute.rounds[_roundNumber];
        uint disputeIDOnArbitratorSide = dispute.disputeIDOnArbitratorSide;

        uint currentRuling = dispute.arbitrator.currentRuling(disputeIDOnArbitratorSide);
        require(uint(dispute.arbitrator.disputeStatus(disputeIDOnArbitratorSide)) == uint(Arbitrator.DisputeStatus.Solved), "The dispute should be solved");
        uint reward;
        if (!round.hasPaid[1] || !round.hasPaid[2]) {
            // Allow to reimburse if funding was unsuccessful.
            reward = round.contributions[_contributor][1] + round.contributions[_contributor][2];
            round.contributions[_contributor][1] = 0;
            round.contributions[_contributor][2] = 0;
        } else if (currentRuling == 0) {
            // Reimburse unspent fees proportionally if there is no winner and loser.
            uint rewardParty1 = round.paidFees[1] > 0
                ? (round.contributions[_contributor][1] * round.totalAppealFeesCollected) / (round.paidFees[1] + round.paidFees[2])
                : 0;
            uint rewardParty2 = round.paidFees[2] > 0
                ? (round.contributions[_contributor][2] * round.totalAppealFeesCollected) / (round.paidFees[1] + round.paidFees[2])
                : 0;

            reward = rewardParty1 + rewardParty2;
            round.contributions[_contributor][1] = 0;
            round.contributions[_contributor][2] = 0;
        } else {
              // Reward the winner.
            reward = round.paidFees[currentRuling] > 0
                ? (round.contributions[_contributor][currentRuling] * round.totalAppealFeesCollected) / round.paidFees[currentRuling]
                : 0;
            round.contributions[_contributor][currentRuling] = 0;
          }

        _contributor.send(reward); // It is the user responsibility to accept ETH.
    }

    /** @dev To be called by the arbitrator of the dispute, to declare winning side.
     *  @param _localDisputeID Index of the dispute on disputes array.
     *  @param _ruling The side which the caller wants to contribute.
     */
    function rule(uint _localDisputeID, uint _ruling) external {
        DisputeStruct storage dispute = disputes[_localDisputeID];
        require(msg.sender == address(dispute.arbitrator), "Unauthorized call.");
        require(_ruling <= NUMBER_OF_CHOICES, "Invalid ruling.");
        require(dispute.isRuled == false, "Is ruled already.");

        dispute.isRuled = true;

        Round storage round = dispute.rounds[dispute.rounds.length-1];

        uint resultRuling = _ruling;
        if (round.hasPaid[1] == true) // If one side paid its fees, the ruling is in its favor. Note that if the other side had also paid, an appeal would have been created.
            resultRuling = 1;
        else if (round.hasPaid[2] == true)
            resultRuling = 2;

        emit Ruling(Arbitrator(msg.sender), dispute.disputeIDOnArbitratorSide, resultRuling);
    }

    /** @dev Lets to submit evidence for a given dispute.
     *  @param _localDisputeID Index of the dispute on disputes array.
     *  @param _evidenceURI Link to evidence.
     */
    function submitEvidence(uint _localDisputeID, string memory _evidenceURI) public {
        DisputeStruct storage dispute = disputes[_localDisputeID];

        require(dispute.isRuled == false, "Is ruled already.");

        emit Evidence(dispute.arbitrator, _localDisputeID, msg.sender, _evidenceURI);
    }
}
