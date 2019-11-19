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
import "@openzeppelin/contracts/math/SafeMath.sol";

/**
 *  @title BinaryArbitrableProxy
 *  This contract acts as a general purpose dispute creator.
 */
contract BinaryArbitrableProxy is IArbitrable, IEvidence {
    Arbitrator arbitrator;

    /** dev Constructor
     *  @param _arbitrator Target global arbitrator for any disputes.
     **/
    constructor(Arbitrator _arbitrator) public {
        arbitrator = _arbitrator;
    }

    using SafeMath for uint;

    uint constant NUMBER_OF_CHOICES = 2;
    enum Party {None, Requester, Respondent}
    uint8 requester = uint8(Party.Requester);
    uint8 respondent = uint8(Party.Respondent);

    struct Round {
      uint[3] paidFees; // Tracks the fees paid by each side in this round.
      bool[3] hasPaid; // True when the side has fully paid its fee. False otherwise.
      uint totalAppealFeesCollected; // Sum of reimbursable appeal fees available to the parties that made contributions to the side that ultimately wins a dispute.
      mapping(address => uint[3]) contributions; // Maps contributors to their contributions for each side.
    }

    struct DisputeStruct {
        bytes arbitratorExtraData;
        bool isRuled;
        Party ruling;
        uint disputeIDOnArbitratorSide;
        Round[] rounds;
    }

    DisputeStruct[] public disputes;
    mapping(uint => uint) public externalIDtoLocalID;


    /** @dev UNTRUSTED. Calls createDispute function of the specified arbitrator to create a dispute.
     *  @param _arbitratorExtraData Extra data for the arbitrator of prospective dispute.
     *  @param _metaevidenceURI Link to metaevidence of prospective dispute.
     */
    function createDispute(bytes calldata _arbitratorExtraData, string calldata _metaevidenceURI) external payable {
        uint disputeID = arbitrator.createDispute.value(msg.value)(NUMBER_OF_CHOICES, _arbitratorExtraData);

        uint localDisputeID = disputes.length++;
        DisputeStruct storage dispute = disputes[localDisputeID];
        dispute.arbitratorExtraData = _arbitratorExtraData;
        dispute.disputeIDOnArbitratorSide = disputeID;
        dispute.rounds.length++;

        externalIDtoLocalID[disputeID] = localDisputeID;

        emit MetaEvidence(localDisputeID, _metaevidenceURI);
        emit Dispute(arbitrator, disputeID, localDisputeID, localDisputeID);

    }

    /** @dev UNTRUSTED. Manages contributions and calls appeal function of the specified arbitrator to appeal a dispute. This function lets appeals be crowdfunded.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _party The side to which the caller wants to contribute.
     */
    function appeal(uint _localDisputeID, Party _party) external payable {
        require(_party != Party.None, "You can't fund an appeal in favor of refusing to arbitrate.");
        uint8 side = uint8(_party);
        DisputeStruct storage dispute = disputes[_localDisputeID];

        (uint appealPeriodStart, uint appealPeriodEnd) = arbitrator.appealPeriod(dispute.disputeIDOnArbitratorSide);
        require(now >= appealPeriodStart && now < appealPeriodEnd, "Funding must be made within the appeal period.");

        Round storage round = dispute.rounds[dispute.rounds.length-1];

        require(!round.hasPaid[side], "Appeal fee has already been paid");

        uint appealCost = arbitrator.appealCost(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);

        uint contribution;

        if(round.paidFees[side] + msg.value >= appealCost){
          contribution = appealCost - round.paidFees[side];
          round.hasPaid[side] = true; 

        } else{
            contribution = msg.value;
        }
        msg.sender.send(msg.value - contribution);
        round.contributions[msg.sender][side] += contribution;
        round.paidFees[side] += contribution;
        round.totalAppealFeesCollected += contribution;

        if(round.hasPaid[requester] && round.hasPaid[respondent]){
            arbitrator.appeal.value(appealCost)(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);
            dispute.rounds.length++;
            round.totalAppealFeesCollected = round.totalAppealFeesCollected.sub(appealCost);
        }
    }

    /** @dev Lets to withdraw any reimbursable fees or rewards after the dispute gets solved.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The side to which the caller wants to contribute.
     *  @param _roundNumber The number of the round caller wants to withdraw from.
     */
    function withdrawFeesAndRewards(uint _localDisputeID, address payable _contributor, uint _roundNumber) external {
        DisputeStruct storage dispute = disputes[_localDisputeID];
        Round storage round = dispute.rounds[_roundNumber];
        uint8 ruling = uint8(dispute.ruling);

        require(dispute.isRuled, "The dispute should be solved");
        uint reward;
        if (!round.hasPaid[requester] || !round.hasPaid[respondent]) {
            // Allow to reimburse if funding was unsuccessful.
            reward = round.contributions[_contributor][requester] + round.contributions[_contributor][respondent];
            round.contributions[_contributor][requester] = 0;
            round.contributions[_contributor][respondent] = 0;
        } else if (Party(ruling) == Party.None) {
            // Reimburse unspent fees proportionally if there is no winner and loser.
            uint rewardRequester = round.paidFees[requester] > 0
                ? (round.contributions[_contributor][requester] * round.totalAppealFeesCollected) / (round.paidFees[requester] + round.paidFees[respondent])
                : 0;
            uint rewardRespondent = round.paidFees[respondent] > 0
                ? (round.contributions[_contributor][respondent] * round.totalAppealFeesCollected) / (round.paidFees[requester] + round.paidFees[respondent])
                : 0;

            reward = rewardRequester + rewardRespondent;
            round.contributions[_contributor][requester] = 0;
            round.contributions[_contributor][respondent] = 0;
        } else {
              // Reward the winner.
            reward = round.paidFees[ruling] > 0
                ? (round.contributions[_contributor][ruling] * round.totalAppealFeesCollected) / round.paidFees[ruling]
                : 0;
            round.contributions[_contributor][ruling] = 0;
          }

        _contributor.send(reward); // It is the user responsibility to accept ETH.
    }

    /** @dev To be called by the arbitrator of the dispute, to declare winning side.
     *  @param _externalDisputeID ID of the dispute in arbitrator contract.
     *  @param _ruling The side to which the caller wants to contribute.
     */
    function rule(uint _externalDisputeID, uint _ruling) external {
        uint _localDisputeID = externalIDtoLocalID[_externalDisputeID];
        DisputeStruct storage dispute = disputes[_localDisputeID];
        require(msg.sender == address(arbitrator), "Unauthorized call.");
        require(_ruling <= NUMBER_OF_CHOICES, "Invalid ruling.");
        require(dispute.isRuled == false, "Is ruled already.");

        dispute.isRuled = true;
        dispute.ruling = Party(_ruling);

        Round storage round = dispute.rounds[dispute.rounds.length-1];

        if (round.hasPaid[requester] == true) // If one side paid its fees, the ruling is in its favor. Note that if the other side had also paid, an appeal would have been created.
            dispute.ruling = Party.Requester;
        else if (round.hasPaid[respondent] == true)
            dispute.ruling = Party.Respondent;

        emit Ruling(Arbitrator(msg.sender), dispute.disputeIDOnArbitratorSide, uint(dispute.ruling));
    }

    /** @dev Allows to submit evidence for a given dispute.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _evidenceURI Link to evidence.
     */
    function submitEvidence(uint _localDisputeID, string memory _evidenceURI) public {
        DisputeStruct storage dispute = disputes[_localDisputeID];

        require(dispute.isRuled == false, "Cannot submit evidence to a resolved dispute.");

        emit Evidence(arbitrator, _localDisputeID, msg.sender, _evidenceURI);
    }

    /** @dev Returns crowdfunding status, useful for user interface implemetations.
     *  @param _localDisputeID Dispute ID as in this contract.
     *  @param _participant Address of crowfunding participant to get details of.
     */
    function crowdfundingStatus(uint _localDisputeID, address _participant) external view returns (uint[3] memory paidFess, bool[3] memory hasPaid, uint totalAppealFeesCollected, uint[3] memory contributions){
        DisputeStruct storage dispute = disputes[_localDisputeID];

        Round memory lastRound = dispute.rounds[dispute.rounds.length - 1];

        return (lastRound.paidFees, lastRound.hasPaid, lastRound.totalAppealFeesCollected, dispute.rounds[dispute.rounds.length - 1].contributions[_participant]);

    }

    /** @dev Proxy getter for arbitration cost
     *  @param  _arbitratorExtraData Extra data for arbitration cost calculation. See arbitrator for details.
     */
    function getArbitrationCost(bytes calldata _arbitratorExtraData) external view returns (uint arbitrationFee) {
        arbitrationFee = arbitrator.arbitrationCost(_arbitratorExtraData);
    }
}
