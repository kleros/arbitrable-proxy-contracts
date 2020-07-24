/**
 *  @authors: [@ferittuncer]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: [0xeF6F9665B3aAC2894Ea4c458F93aBA5BB8f8b86d, 0xc7e49251807780dFBbCA72778890B80bd946590B]
 */

pragma solidity >=0.6;

import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

/**
 *  @title BinaryArbitrableProxy
 *  This contract acts as a general purpose dispute creator.
 */
contract ArbitrableProxy is IArbitrable, IEvidence {

    using CappedMath for uint; // Operations bounded between 0 and 2**256 - 1.
    address public governor = msg.sender;
    IArbitrator public arbitrator;

    // The required fee stake that a party must pay depends on who won the previous round and is proportional to the arbitration cost such that the fee stake for a round is stake multiplier * arbitration cost for that round.
    // Multipliers are in basis points.
    uint public winnerStakeMultiplier; // Multiplier for calculating the fee stake paid by the party that won the previous round.
    uint public loserStakeMultiplier; // Multiplier for calculating the fee stake paid by the party that lost the previous round.
    uint public sharedStakeMultiplier; // Multiplier for calculating the fee stake that must be paid in the case where there isn't a winner and loser (e.g. when it's the first round or the arbitrator ruled "refused to rule"/"could not rule").
    uint public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.


    /** @dev Constructor
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
        mapping(uint => uint) paidFees; // Tracks the fees paid by each side in this round.
        mapping(uint => bool) hasPaid; // True when the side has fully paid its fee. False otherwise.
        mapping(address => mapping(uint => uint)) contributions; // Maps contributors to their contributions for each side.
        mapping(address => uint[]) contributedTo; // Tracks rulings options that got contribution from users. Helpful for iterating during reward distribution. Max three ruling options allowed.
        uint256 feeRewards; // Sum of reimbursable appeal fees available to the parties that made contributions to the side that ultimately wins a dispute.
        uint[] partiallyFundedSides; // Stores the sides that received contributions in this round.
        uint[] fundedSides; // Stores the sides that are fully funded.
        uint appealFee; // Fee paid for appeal. Not constant even if the arbitrator is not changing because arbitrator can change this fee.
    }

    struct DisputeStruct {
        bytes arbitratorExtraData;
        bool isRuled;
        uint ruling;
        uint disputeIDOnArbitratorSide;
        uint numberOfChoices;
    }

    DisputeStruct[] public disputes;
    mapping(uint => uint) public externalIDtoLocalID;
    mapping(uint => Round[]) public disputeIDRoundIDtoRound;
    mapping(uint => mapping (address => bool)) public withdrewAlready;

    /** @dev TRUSTED. Calls createDispute function of the specified arbitrator to create a dispute.
        Note that we don’t need to check that msg.value is enough to pay arbitration fees as it’s the responsibility of the arbitrator contract.
     *  @param _arbitratorExtraData Extra data for the arbitrator of prospective dispute.
     *  @param _metaevidenceURI Link to metaevidence of prospective dispute.
     *  @param _numberOfChoices Number of ruling options.
     */
    function createDispute(bytes calldata _arbitratorExtraData, string calldata _metaevidenceURI, uint _numberOfChoices) external payable returns(uint disputeID) {
        disputeID = arbitrator.createDispute.value(msg.value)(_numberOfChoices, _arbitratorExtraData);

        disputes.push(DisputeStruct({
            arbitratorExtraData: _arbitratorExtraData,
            isRuled: false,
            ruling: 0,
            disputeIDOnArbitratorSide: disputeID,
            numberOfChoices: _numberOfChoices
          }));

        uint localDisputeID = disputes.length - 1;
        externalIDtoLocalID[disputeID] = localDisputeID;

        disputeIDRoundIDtoRound[localDisputeID].push(
          Round({
          feeRewards: 0,
          partiallyFundedSides: new uint[](0),
          fundedSides: new uint[](0),
          appealFee: 0
        })
      );

        emit MetaEvidence(localDisputeID, _metaevidenceURI);
        emit Dispute(arbitrator, disputeID, localDisputeID, localDisputeID);
    }

    /** @dev Returns the contribution value and remainder from available ETH and required amount.
     *  @param _available The amount of ETH available for the contribution.
     *  @param _requiredAmount The amount of ETH required for the contribution.
     *  @return taken The amount of ETH taken.
     *  @return remainder The amount of ETH left from the contribution.
     */
    function calculateContribution(uint _available, uint _requiredAmount)
        internal
        pure
        returns(uint taken, uint remainder)
    {
        if (_requiredAmount > _available)
            return (_available, 0); // Take whatever is available, return 0 as leftover ETH.

        remainder = _available - _requiredAmount;
        return (_requiredAmount, remainder);
    }

    /** @dev TRUSTED. Manages contributions and calls appeal function of the specified arbitrator to appeal a dispute. This function lets appeals be crowdfunded.
        Note that we don’t need to check that msg.value is enough to pay arbitration fees as it’s the responsibility of the arbitrator contract.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _side The side to which the caller wants to contribute.
     */
    function fundAppeal(uint _localDisputeID, uint _side) external payable {
        DisputeStruct storage dispute = disputes[_localDisputeID];
        require(_side <= dispute.numberOfChoices, "There is no such side to fund.");

        (uint appealPeriodStart, uint appealPeriodEnd) = arbitrator.appealPeriod(dispute.disputeIDOnArbitratorSide);
        require(now >= appealPeriodStart && now < appealPeriodEnd, "Funding must be made within the appeal period.");

        uint winner = arbitrator.currentRuling(dispute.disputeIDOnArbitratorSide);
        uint multiplier;

        if (winner == _side){
            multiplier = winnerStakeMultiplier;
        } else if (winner == 0){
            multiplier = sharedStakeMultiplier;
        } else {
            multiplier = loserStakeMultiplier;
            require((_side==winner) || (now-appealPeriodStart < (appealPeriodEnd-appealPeriodStart)/2), "The loser must contribute during the first half of the appeal period.");
        }

        uint appealCost = arbitrator.appealCost(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);
        uint totalCost = appealCost.addCap(appealCost.mulCap(multiplier) / MULTIPLIER_DIVISOR);

        Round[] storage rounds = disputeIDRoundIDtoRound[_localDisputeID];
        Round storage lastRound = disputeIDRoundIDtoRound[_localDisputeID][rounds.length - 1];
        require(!lastRound.hasPaid[_side], "Appeal fee has already been paid.");
        require(msg.value > 0, "Can't contribute zero");

        if (lastRound.paidFees[_side] == 0)
            lastRound.partiallyFundedSides.push(_side);

        if (lastRound.contributions[msg.sender][_side] == 0)
            lastRound.contributedTo[msg.sender].push(_side);

        uint contribution = totalCost.subCap(lastRound.paidFees[_side]) > msg.value ? msg.value : totalCost.subCap(lastRound.paidFees[_side]);

        lastRound.contributions[msg.sender][uint(_side)] += contribution;
        lastRound.paidFees[uint(_side)] += contribution;
        lastRound.feeRewards += contribution;

        if (lastRound.paidFees[_side] >= totalCost) {
            lastRound.fundedSides.push(_side);
            lastRound.hasPaid[_side] = true;
        }

        if (lastRound.fundedSides.length > 1) {
            // At least two sides are fully funded.
            rounds.push(Round({
              feeRewards: 0,
              partiallyFundedSides: new uint[](0),
              fundedSides: new uint[](0),
              appealFee: 0
            }));

            lastRound.feeRewards = lastRound.feeRewards.subCap(appealCost);
            lastRound.appealFee = appealCost;
            arbitrator.appeal.value(appealCost)(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);
        }

        msg.sender.send(msg.value.subCap(contribution)); // Deliberate use of send in order to not block the contract in case of reverting fallback.
    }


    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _roundNumber The number of the round caller wants to withdraw from.
     */
    function withdrawFeesAndRewardsForSide(uint _localDisputeID, address payable _contributor, uint _roundNumber, uint _side) public {
        DisputeStruct storage dispute = disputes[_localDisputeID];

        Round storage round = disputeIDRoundIDtoRound[_localDisputeID][_roundNumber];
        uint8 ruling = uint8(dispute.ruling);

        require(dispute.isRuled, "The dispute should be solved");
        uint reward;

        if (!round.hasPaid[_side]) {
            // Allow to reimburse if funding was unsuccessful.
            reward = round.contributions[_contributor][_side];
            _contributor.send(reward); // User is responsible for accepting the reward.


        } else if (ruling == 0 || !round.hasPaid[ruling]) {

            // Reimburse unspent fees proportionally if there is no winner and loser.
            reward = round.appealFee > 0 // Means appeal took place.
                ? (round.contributions[_contributor][_side] * round.feeRewards) / (round.feeRewards - round.appealFee)
                : 0;

                _contributor.send(reward); // User is responsible for accepting the reward.

        } else if(ruling == _side) {

            // Reward the winner.
            reward = round.paidFees[ruling] > 0
                ? (round.contributions[_contributor][_side] * round.feeRewards) / round.paidFees[ruling]
                : 0;
                _contributor.send(reward); // User is responsible for accepting the reward.
          }
          round.contributions[_contributor][ruling] = 0;

    }

    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _roundNumber The number of the round caller wants to withdraw from.
     */
    function withdrawFeesAndRewards(uint _localDisputeID, address payable _contributor, uint _roundNumber) public {
        Round storage round = disputeIDRoundIDtoRound[_localDisputeID][_roundNumber];
        for (uint contributionNumber = 0; contributionNumber < round.contributedTo[_contributor].length; contributionNumber++) {
            withdrawFeesAndRewardsForSide(_localDisputeID, _contributor, _roundNumber, round.contributedTo[_contributor][contributionNumber]);
        }
    }

    /** @dev Allows to withdraw any rewards or reimbursable fees after the dispute gets resolved, for all rounds.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     */
    function withdrawFeesAndRewardsForAllRounds(uint _localDisputeID, address payable _contributor) external {
        require(withdrewAlready[_localDisputeID][_contributor] == false, "This contributor withdrew all already.");
        for (uint roundNumber = 0; roundNumber < disputeIDRoundIDtoRound[_localDisputeID].length; roundNumber++) {
            withdrawFeesAndRewards(_localDisputeID, _contributor, roundNumber);
        }

        withdrewAlready[_localDisputeID][_contributor] = true;
    }

    /** @dev To be called by the arbitrator of the dispute, to declare winning side.
     *  @param _externalDisputeID ID of the dispute in arbitrator contract.
     *  @param _ruling The ruling choice of the arbitration.
     */
    function rule(uint _externalDisputeID, uint _ruling) external override {
        uint _localDisputeID = externalIDtoLocalID[_externalDisputeID];
        DisputeStruct storage dispute = disputes[_localDisputeID];
        require(msg.sender == address(arbitrator), "Only the arbitrator can execute this.");
        require(_ruling <= dispute.numberOfChoices, "Invalid ruling.");
        require(dispute.isRuled == false, "Is ruled already.");

        dispute.isRuled = true;
        dispute.ruling = _ruling;

        Round[] storage rounds = disputeIDRoundIDtoRound[_localDisputeID];
        Round storage lastRound = disputeIDRoundIDtoRound[_localDisputeID][rounds.length - 1];
        // If one side paid its fees, the ruling is in its favor. Note that if any other side had also paid, an appeal would have been created.
        if (lastRound.fundedSides.length == 1) {
            dispute.ruling = lastRound.fundedSides[0];
        }

        emit Ruling(IArbitrator(msg.sender), _externalDisputeID, uint(dispute.ruling));
    }

    /** @dev Allows to submit evidence for a given dispute.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _evidenceURI Link to evidence.
     */
    function submitEvidence(uint _localDisputeID, string calldata _evidenceURI) external {
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

    /** @dev Gets the information of a round of a dispute.
     *  @param _localDisputeID ID of the dispute.
     *  @param _round The round to be queried.
     *  @return appealed Whether the round is appealed or not.
     *  @return feeRewards Total fees collected for parties excluding appeal cost.
     *  @return partiallyFundedSides Tracks ruling options that are partially funded for appeals.
     *  @return fundedSides Tracks ruling options that are fully funded for appeals.
     *  @return appealFee Appeal fee of this round.
     */
    function getRoundInfo(uint _localDisputeID, uint _round)
        external
        view
        returns (
            bool appealed,
            uint feeRewards,
            uint[] memory partiallyFundedSides,
            uint[] memory fundedSides,
            uint appealFee
        )
    {
        Round storage round = disputeIDRoundIDtoRound[_localDisputeID][_round];
        return (
            _round != (disputeIDRoundIDtoRound[_localDisputeID].length - 1),
            round.feeRewards,
            round.partiallyFundedSides,
            round.fundedSides,
            round.appealFee
        );
    }

    /** @dev Returns stake multipliers.
     *  @return winner Winners stake multiplier.
     *  @return loser Losers stake multiplier.
     *  @return shared Multiplier when it's tied.
     *  @return divisor Multiplier divisor.
     */
    function getMultipliers() external view returns(uint winner, uint loser, uint shared, uint divisor){
      return (winnerStakeMultiplier, loserStakeMultiplier, sharedStakeMultiplier, MULTIPLIER_DIVISOR);
    }

    /** @dev Returns crowdfunding status, useful for user interfaces.
     *  @param _localDisputeID Dispute ID as in this contract.
     *  @param _participant Address of crowdfunding participant to get details of.
     *  @return paidFees Total amount of paid fees for each each partially funded side.
     *  @return hasPaid True if this side has been fully funded.
     *  @return feeRewards Total amount of reward available to distribute at the moment.
     *  @return contributions Contributions to partially funded sides, of given participant.
     *  @return partiallyFundedSides Complete list of partially funded sides. All other returned array values are corresponding to these sides.
     */
    function crowdfundingStatus(uint _localDisputeID, address _participant) external view returns (uint[] memory paidFees, bool[] memory hasPaid, uint feeRewards, uint[] memory contributions, uint[] memory partiallyFundedSides) {
        Round[] storage rounds = disputeIDRoundIDtoRound[_localDisputeID];
        Round storage lastRound = disputeIDRoundIDtoRound[_localDisputeID][rounds.length -1];
        uint noOfPartiallyFundedSides = lastRound.partiallyFundedSides.length;

        uint[] memory participantsContributionsForSide = new uint[](noOfPartiallyFundedSides);
        uint[] memory totalContributionsForSide = new uint[](noOfPartiallyFundedSides);
        bool[] memory hasPaid = new bool[](noOfPartiallyFundedSides);

        for (uint i = 0; i < noOfPartiallyFundedSides; i++) {
          totalContributionsForSide[i] = lastRound.paidFees[lastRound.partiallyFundedSides[i]];
          participantsContributionsForSide[i] = lastRound.contributions[_participant][lastRound.partiallyFundedSides[i]];
          if(lastRound.hasPaid[lastRound.partiallyFundedSides[i]]) hasPaid[i] = true;
        }

        return (totalContributionsForSide, hasPaid, lastRound.feeRewards, participantsContributionsForSide, lastRound.partiallyFundedSides);
    }

    /** @dev Proxy getter for arbitration cost.
     *  @param  _arbitratorExtraData Extra data for arbitration cost calculation. See arbitrator for details.
     *  @return arbitrationFee Arbitration cost of the arbitrator of this contract.
     */
    function getArbitrationCost(bytes calldata _arbitratorExtraData) external view returns (uint arbitrationFee) {
        arbitrationFee = arbitrator.arbitrationCost(_arbitratorExtraData);
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
        for (uint i = 0; i < disputes.length; i++) {
            if(disputes[i].isRuled == false){
                noOfOpenDisputes++;
            }
        }
        openDisputes = new uint[](noOfOpenDisputes);

        uint count = 0;
        hasMore = true;
        uint i;
        for (i = _cursor; i < disputes.length && (count < _count || 0 == _count); i++) {
            if(disputes[i].isRuled == false){
                openDisputes[count++] = disputes[i].disputeIDOnArbitratorSide;
            }
        }

        if(i == disputes.length) hasMore = false;

    }
}
