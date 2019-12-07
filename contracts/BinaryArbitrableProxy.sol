/**
 *  @authors: [@ferittuncer]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity >=0.5 <0.6.0;

import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

/**
 *  @title BinaryArbitrableProxy
 *  This contract acts as a general purpose dispute creator.
 */
contract BinaryArbitrableProxy is IArbitrable, IEvidence {

    address governor = msg.sender;
    IArbitrator arbitrator;
    // The required fee stake that a party must pay depends on who won the previous round and is proportional to the arbitration cost such that the fee stake for a round is stake multiplier * arbitration cost for that round.
    // Multipliers are in basis points.
    uint public winnerStakeMultiplier; // Multiplier for calculating the fee stake paid by the party that won the previous round.
    uint public loserStakeMultiplier; // Multiplier for calculating the fee stake paid by the party that lost the previous round.
    uint public sharedStakeMultiplier; // Multiplier for calculating the fee stake that must be paid in the case where there isn't a winner and loser (e.g. when it's the first round or the arbitrator ruled "refused to rule"/"could not rule").
    uint public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    uint constant NUMBER_OF_CHOICES = 2;
    enum Party {None, Requester, Respondent}


    /** dev Constructor
     *  @param _arbitrator Target global arbitrator for any disputes.
     *  @param _winnerStakeMultiplier Multiplier of the arbitration cost that the winner has to pay as fee stake for a round in basis points.
     *  @param _loserStakeMultiplier Multiplier of the arbitration cost that the loser has to pay as fee stake for a round in basis points.
     *  @param _sharedStakeMultiplier Multiplier of the arbitration cost that each party must pay as fee stake for a round when there isn't a winner/loser in the previous round (e.g. when it's the first round or the arbitrator refused to or did not rule). In basis points.
     */
    constructor(IArbitrator _arbitrator, uint _winnerStakeMultiplier, uint _loserStakeMultiplier, uint _sharedStakeMultiplier) public {
        arbitrator = _arbitrator;
        winnerStakeMultiplier = _winnerStakeMultiplier;
        loserStakeMultiplier = _loserStakeMultiplier;
        sharedStakeMultiplier = _sharedStakeMultiplier;
    }

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

    /** @dev TRUSTED. Calls createDispute function of the specified arbitrator to create a dispute.
        Note that we don’t need to check that msg.value is enough to pay arbitration fees as it’s the responsibility of the arbitrator contract.
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

    /** @dev TRUSTED. Manages contributions and calls appeal function of the specified arbitrator to appeal a dispute. This function lets appeals be crowdfunded.
        Note that we don’t need to check that msg.value is enough to pay arbitration fees as it’s the responsibility of the arbitrator contract.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _party The side to which the caller wants to contribute.
     */
    function appeal(uint _localDisputeID, Party _party) external payable {
        require(_party != Party.None, "You can't fund an appeal in favor of refusing to arbitrate.");
        uint8 side = uint8(_party);
        DisputeStruct storage dispute = disputes[_localDisputeID];

        (uint appealPeriodStart, uint appealPeriodEnd) = arbitrator.appealPeriod(dispute.disputeIDOnArbitratorSide);
        require(now >= appealPeriodStart && now < appealPeriodEnd, "Funding must be made within the appeal period.");

        Round storage round = dispute.rounds[dispute.rounds.length - 1];


        require(!round.hasPaid[side], "Appeal fee has already been paid");
        uint appealCost = arbitrator.appealCost(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);

        uint currentRuling = arbitrator.currentRuling(dispute.disputeIDOnArbitratorSide);
        uint multiplier;
        if (_party == Party(currentRuling)){
            multiplier = winnerStakeMultiplier;
        } else if (Party(currentRuling) == Party.None){
            multiplier = sharedStakeMultiplier;
        } else {
            require(now - appealPeriodStart < (appealPeriodEnd - appealPeriodStart)/2, "The loser must pay during the first half of the appeal period.");
            multiplier = loserStakeMultiplier;
        }

        uint totalCost = CappedMath.addCap(appealCost,((CappedMath.mulCap(appealCost, multiplier)) / MULTIPLIER_DIVISOR));

        uint contribution;

        if(round.paidFees[side] + msg.value >= totalCost){
            contribution = CappedMath.subCap(totalCost, round.paidFees[side]);
            round.hasPaid[side] = true;
        } else{
            contribution = msg.value;
        }

        msg.sender.send(msg.value - contribution);
        round.contributions[msg.sender][side] += contribution;
        round.paidFees[side] += contribution;
        round.totalAppealFeesCollected += contribution;

        if(round.hasPaid[uint8(Party.Requester)] && round.hasPaid[uint8(Party.Respondent)]){
            dispute.rounds.length++;
            round.totalAppealFeesCollected = CappedMath.subCap(round.totalAppealFeesCollected, appealCost);
            arbitrator.appeal.value(appealCost)(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);
        }

    }

    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved.
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
        if (!round.hasPaid[uint8(Party.Requester)] || !round.hasPaid[uint8(Party.Respondent)]) {
            // Allow to reimburse if funding was unsuccessful.
            reward = round.contributions[_contributor][uint8(Party.Requester)] + round.contributions[_contributor][uint8(Party.Respondent)];
            round.contributions[_contributor][uint8(Party.Requester)] = 0;
            round.contributions[_contributor][uint8(Party.Respondent)] = 0;
        } else if (Party(ruling) == Party.None) {
            // Reimburse unspent fees proportionally if there is no winner and loser.
            uint rewardRequester = round.paidFees[uint8(Party.Requester)] > 0
                ? (round.contributions[_contributor][uint8(Party.Requester)] * round.totalAppealFeesCollected) / (round.paidFees[uint8(Party.Requester)] + round.paidFees[uint8(Party.Respondent)])
                : 0;
            uint rewardRespondent = round.paidFees[uint8(Party.Respondent)] > 0
                ? (round.contributions[_contributor][uint8(Party.Respondent)] * round.totalAppealFeesCollected) / (round.paidFees[uint8(Party.Requester)] + round.paidFees[uint8(Party.Respondent)])
                : 0;

            reward = rewardRequester + rewardRespondent;
            round.contributions[_contributor][uint8(Party.Requester)] = 0;
            round.contributions[_contributor][uint8(Party.Respondent)] = 0;
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

        Round storage round = dispute.rounds[dispute.rounds.length - 1];

        if (round.hasPaid[uint8(Party.Requester)] == true) // If one side paid its fees, the ruling is in its favor. Note that if the other side had also paid, an appeal would have been created.
            dispute.ruling = Party.Requester;
        else if (round.hasPaid[uint8(Party.Respondent)] == true)
            dispute.ruling = Party.Respondent;

        emit Ruling(IArbitrator(msg.sender), dispute.disputeIDOnArbitratorSide, uint(dispute.ruling));
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

    /** @dev Changes the proportion of appeal fees that must be paid when there is no winner or loser.
     *  @param _sharedStakeMultiplier The new tie multiplier value respect to MULTIPLIER_DIVISOR.
     */
    function changesharedStakeMultiplier(uint _sharedStakeMultiplier) external {
        require(msg.sender == governor, "Unauthorized call.");
        sharedStakeMultiplier = _sharedStakeMultiplier;
    }

    /** @dev Changes the proportion of appeal fees that must be paid by winner.
     *  @param _winnerStakeMultiplier The new winner multiplier value respect to MULTIPLIER_DIVISOR.
     */
    function changewinnerStakeMultiplier(uint _winnerStakeMultiplier) external {
        require(msg.sender == governor, "Unauthorized call.");
        winnerStakeMultiplier = _winnerStakeMultiplier;
    }

    /** @dev Changes the proportion of appeal fees that must be paid by loser.
     *  @param _loserStakeMultiplier The new loser multiplier value respect to MULTIPLIER_DIVISOR.
     */
    function changeloserStakeMultiplier(uint _loserStakeMultiplier) external {
        require(msg.sender == governor, "Unauthorized call.");
        loserStakeMultiplier = _loserStakeMultiplier;
    }

    /** @dev Gets the information of a round of a dispute.
     *  @param _localDisputeID ID of the dispute.
     *  @param _round The round to be queried.
     *  @return appealed Whether the round is appealed or not.
     *  @return paidFees Total fees paid for each party.
     *  @return hasPaid Whether given party paid required amount or not, for each party.
     *  @return totalAppealFeesCollected Total fees collected for parties excluding appeal cost.
     */
    function getRoundInfo(uint _localDisputeID, uint _round)
        external
        view
        returns (
            bool appealed,
            uint[3] memory paidFees,
            bool[3] memory hasPaid,
            uint totalAppealFeesCollected
        )
    {
        DisputeStruct storage dispute = disputes[_localDisputeID];
        Round storage round = dispute.rounds[_round];
        return (
            _round != (dispute.rounds.length - 1),
            round.paidFees,
            round.hasPaid,
            round.totalAppealFeesCollected
        );
    }

    /** @dev Returns crowdfunding status, useful for user interfaces.
     *  @param _localDisputeID Dispute ID as in this contract.
     *  @param _participant Address of crowfunding participant to get details of.
     *  @return Total fees paid for each party in the last round.
     *  @return Whether given party paid required amount or not, for each party, in the last round.
     *  @return totalAppealFeesCollected Total fees collected for parties excluding appeal cost, in the last round.
      * @return contributions Contributions of given participant in the last round.
     */
    function crowdfundingStatus(uint _localDisputeID, address _participant) external view returns (uint[3] memory paidFess, bool[3] memory hasPaid, uint totalAppealFeesCollected, uint[3] memory contributions) {
        DisputeStruct storage dispute = disputes[_localDisputeID];

        Round memory lastRound = dispute.rounds[dispute.rounds.length - 1];

        return (lastRound.paidFees, lastRound.hasPaid, lastRound.totalAppealFeesCollected, dispute.rounds[dispute.rounds.length - 1].contributions[_participant]);
    }

    /** @dev Proxy getter for arbitration cost.
     *  @param  _arbitratorExtraData Extra data for arbitration cost calculation. See arbitrator for details.
     *  @return arbitrationFee Arbitration cost of the arbitrator of this contract.
     */
    function getArbitrationCost(bytes calldata _arbitratorExtraData) external view returns (uint arbitrationFee) {
        arbitrationFee = arbitrator.arbitrationCost(_arbitratorExtraData);
    }


}
