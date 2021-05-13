// SPDX-License-Identifier: MIT

/**
 *  @authors: [@ferittuncer]
 *  @reviewers: [@fnanni-0*, @unknownunknown1*, @mtsalenc*]
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity ^0.7.0;

import "@kleros/ethereum-libraries/contracts/CappedMath.sol";
import "@kleros/dispute-resolver-interface-contract/contracts/solc-0.7.x/IDisputeResolver.sol";

/**
 *  @title ArbitrableProxy
 *  A general purpose arbitrable contract. Supports non-binary rulings.
 */
contract ArbitrableProxy is IDisputeResolver {
    using CappedMath for uint256; // Operations bounded between 0 and `type(uint256).max`.

    uint256 public constant MAX_NO_OF_CHOICES = type(uint256).max;

    struct Round {
        mapping(uint256 => uint256) paidFees; // Tracks the fees paid for each ruling option in this round.
        mapping(uint256 => bool) hasPaid; // True if this ruling option was fully funded, false otherwise.
        mapping(address => mapping(uint256 => uint256)) contributions; // Maps contributors to their contributions for each side.
        uint256 feeRewards; // Sum of reimbursable appeal fees available to the parties that made contributions to the ruling that ultimately wins a dispute.
        uint256[] fundedRulings; // Stores the ruling options that are fully funded.
    }

    struct DisputeStruct {
        bytes arbitratorExtraData;
        bool isRuled;
        uint256 ruling;
        uint256 disputeIDOnArbitratorSide;
    }

    address public governor = msg.sender; // By default the governor is the deployer of this contract.
    IArbitrator public immutable arbitrator; // Arbitrator is set in constructor and never changed.

    // The required fee stake that a party must pay depends on who won the previous round and is proportional to the arbitration cost such that the fee stake for a round is stake multiplier * arbitration cost for that round.
    uint256 public winnerStakeMultiplier = 10000; // Multiplier of the arbitration cost that the winner has to pay as fee stake for a round in basis points. Default is 1x of appeal fee.
    uint256 public loserStakeMultiplier = 20000; // Multiplier of the arbitration cost that the loser has to pay as fee stake for a round in basis points. Default is 2x of appeal fee.
    uint256 public loserAppealPeriodMultiplier = 5000; // Multiplier of the appeal period for losers (any other ruling options) in basis points. Default is 1/2 of original appeal period.
    uint256 public constant DENOMINATOR = 10000; // Denominator for multipliers.

    DisputeStruct[] public disputes;
    mapping(uint256 => uint256) public override externalIDtoLocalID; // Maps external (arbitrator side) dispute ids to local dispute ids.
    mapping(uint256 => Round[]) public disputeIDtoRoundArray; // Maps dispute ids to round arrays.
    mapping(uint256 => uint256) public override numberOfRulingOptions; // Maps localDisputeIDs to number of possible ruling options.

    /** @dev Constructor
     *  @param _arbitrator Target global arbitrator for any disputes.
     */
    constructor(IArbitrator _arbitrator) {
        arbitrator = _arbitrator;
    }

    /** @dev Allows to submit evidence for a given dispute.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _evidenceURI Link to evidence.
     */
    function submitEvidence(uint256 _localDisputeID, string calldata _evidenceURI) external override {
        DisputeStruct storage dispute = disputes[_localDisputeID];
        require(dispute.isRuled == false, "Cannot submit evidence to a resolved dispute.");

        emit Evidence(arbitrator, _localDisputeID, msg.sender, _evidenceURI);
    }

    /** @dev TRUSTED. Calls createDispute function of the specified arbitrator to create a dispute.
        Note that we don’t need to check that msg.value is enough to pay arbitration fees as it’s the responsibility of the arbitrator contract.
     *  @param _arbitratorExtraData Extra data for the arbitrator of prospective dispute.
     *  @param _metaevidenceURI Link to metaevidence of prospective dispute.
     *  @param _numberOfRulingOptions Number of ruling options.
     *  @return disputeID Dispute id (on arbitrator side) of the dispute created.
     */
    function createDispute(
        bytes calldata _arbitratorExtraData,
        string calldata _metaevidenceURI,
        uint256 _numberOfRulingOptions
    ) external payable returns (uint256 disputeID) {
        if (_numberOfRulingOptions == 0) _numberOfRulingOptions = MAX_NO_OF_CHOICES;

        uint256 arbitrationCost = arbitrator.arbitrationCost(_arbitratorExtraData);
        disputeID = arbitrator.createDispute{value: msg.value}(_numberOfRulingOptions, _arbitratorExtraData);

        uint256 localDisputeID = disputes.length;

        disputes.push(DisputeStruct({arbitratorExtraData: _arbitratorExtraData, isRuled: false, ruling: 0, disputeIDOnArbitratorSide: disputeID}));

        externalIDtoLocalID[disputeID] = localDisputeID;

        numberOfRulingOptions[localDisputeID] = _numberOfRulingOptions;
        disputeIDtoRoundArray[localDisputeID].push();

        emit MetaEvidence(localDisputeID, _metaevidenceURI);
        emit Dispute(arbitrator, disputeID, localDisputeID, localDisputeID);

        msg.sender.transfer(msg.value - arbitrationCost); // Return excess msg.value to sender.
    }

    /** @dev TRUSTED. Manages contributions and calls appeal function of the specified arbitrator to appeal a dispute. This function lets appeals be crowdfunded.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _ruling The ruling to which the caller wants to contribute.
     *  @return fullyFunded Whether _ruling was fully funded after the call.
     */
    function fundAppeal(uint256 _localDisputeID, uint256 _ruling) external payable override returns (bool fullyFunded) {
        require(_ruling <= numberOfRulingOptions[_localDisputeID], "There is no such ruling to fund.");
        DisputeStruct storage dispute = disputes[_localDisputeID];
        uint256 disputeID = dispute.disputeIDOnArbitratorSide; // Intermediate variable to make reads cheaper.

        uint256 originalCost;
        uint256 totalCost;
        {
            uint256 currentRuling = arbitrator.currentRuling(disputeID); // Intermediate variable to make reads cheaper.
            (originalCost, totalCost) = appealCost(disputeID, dispute.arbitratorExtraData, _ruling, currentRuling);
            checkAppealPeriod(disputeID, _ruling, currentRuling); // Reverts if appeal period has been expired for _ruling.
        }

        Round[] storage rounds = disputeIDtoRoundArray[_localDisputeID];
        uint256 lastRoundIndex = rounds.length - 1; // Intermediate variable to make reads cheaper.
        Round storage lastRound = rounds[lastRoundIndex];

        require(!lastRound.hasPaid[_ruling], "Appeal fee has already been paid.");
        uint256 paidFeesInLastRound = lastRound.paidFees[_ruling]; // Intermediate variable to make reads cheaper.

        uint256 contribution = totalCost.subCap(paidFeesInLastRound) > msg.value ? msg.value : totalCost.subCap(paidFeesInLastRound);
        lastRound.paidFees[_ruling] += contribution;

        emit Contribution(_localDisputeID, lastRoundIndex, _ruling, msg.sender, contribution);
        lastRound.contributions[msg.sender][_ruling] += contribution;

        paidFeesInLastRound = lastRound.paidFees[_ruling]; // Intermediate variable to make reads cheaper.

        if (paidFeesInLastRound >= totalCost) {
            lastRound.feeRewards += paidFeesInLastRound;
            lastRound.fundedRulings.push(_ruling);
            lastRound.hasPaid[_ruling] = true;
            emit RulingFunded(_localDisputeID, lastRoundIndex, _ruling);
        }

        if (lastRound.fundedRulings.length == 2) {
            // At least two ruling options are fully funded.
            rounds.push();

            lastRound.feeRewards = lastRound.feeRewards.subCap(originalCost);
            arbitrator.appeal{value: originalCost}(disputeID, dispute.arbitratorExtraData);
        }

        msg.sender.transfer(msg.value.subCap(contribution)); // Sending extra value back to contributor.

        return lastRound.hasPaid[_ruling];
    }

    /** @dev Allows to withdraw any rewards or reimbursable fees after the dispute gets resolved. For multiple rulings options and for all rounds at once.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _contributedTo Rulings that received contributions from contributor.
     */
    function withdrawFeesAndRewardsForAllRounds(
        uint256 _localDisputeID,
        address payable _contributor,
        uint256[] memory _contributedTo
    ) external override {
        uint256 noOfRounds = disputeIDtoRoundArray[_localDisputeID].length;
        for (uint256 roundNumber = 0; roundNumber < noOfRounds; roundNumber++) {
            withdrawFeesAndRewardsForMultipleRulings(_localDisputeID, _contributor, roundNumber, _contributedTo);
        }
    }

    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved for multiple ruling options at once.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _roundNumber The number of the round caller wants to withdraw from.
     *  @param _contributedTo Rulings that received contributions from contributor.
     */
    function withdrawFeesAndRewardsForMultipleRulings(
        uint256 _localDisputeID,
        address payable _contributor,
        uint256 _roundNumber,
        uint256[] memory _contributedTo
    ) public override {
        uint256 contributionArrayLength = _contributedTo.length;
        for (uint256 contributionNumber = 0; contributionNumber < contributionArrayLength; contributionNumber++) {
            withdrawFeesAndRewards(_localDisputeID, _contributor, _roundNumber, _contributedTo[contributionNumber]);
        }
    }

    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _roundNumber The number of the round caller wants to withdraw from.
     *  @param _ruling The ruling option that the caller wants to withdraw fees and rewards related to it.
     *  @return amount Reward amount that is to be withdrawn. Might be zero if arguments are not qualifying for a reward or reimbursement, or it might be withdrawn already.
     */
    function withdrawFeesAndRewards(
        uint256 _localDisputeID,
        address payable _contributor,
        uint256 _roundNumber,
        uint256 _ruling
    ) public override returns (uint256 amount) {
        DisputeStruct storage dispute = disputes[_localDisputeID];
        require(dispute.isRuled, "The dispute should be solved");

        Round storage round = disputeIDtoRoundArray[_localDisputeID][_roundNumber];

        amount = getWithdrawableAmount(round, _contributor, _ruling, dispute.ruling);

        if (amount != 0 && _contributor.send(amount)) {
            round.contributions[_contributor][_ruling] = 0;
            emit Withdrawal(_localDisputeID, _roundNumber, _ruling, _contributor, amount);
        }
    }

    /** @dev To be called by the arbitrator of the dispute, to declare winning ruling.
     *  @param _externalDisputeID ID of the dispute in arbitrator contract.
     *  @param _ruling The ruling choice of the arbitration.
     */
    function rule(uint256 _externalDisputeID, uint256 _ruling) external override {
        uint256 localDisputeID = externalIDtoLocalID[_externalDisputeID];
        DisputeStruct storage dispute = disputes[localDisputeID];
        require(msg.sender == address(arbitrator), "Only the arbitrator can execute this.");
        require(_ruling <= numberOfRulingOptions[localDisputeID], "Invalid ruling.");
        require(dispute.isRuled == false, "This dispute has been ruled already.");

        dispute.isRuled = true;
        dispute.ruling = _ruling;

        Round[] storage rounds = disputeIDtoRoundArray[localDisputeID];
        Round storage lastRound = disputeIDtoRoundArray[localDisputeID][rounds.length - 1];
        // If only one ruling option is funded, it wins by default. Note that if any other ruling had funded, an appeal would have been created.
        if (lastRound.fundedRulings.length == 1) {
            dispute.ruling = lastRound.fundedRulings[0];
        }

        emit Ruling(IArbitrator(msg.sender), _externalDisputeID, uint256(dispute.ruling));
    }

    /** @dev Changes governor.
     *  @param _newGovernor The address of the new governor.
     */
    function setGovernor(address _newGovernor) external {
        require(msg.sender == governor, "Only the governor can execute this.");
        governor = _newGovernor;
    }

    /** @dev Changes the proportion of appeal fees that must be paid by winner and loser and changes the appeal period portion for losers.
     *  @param _winnerStakeMultiplier The new winner stake multiplier value respect to DENOMINATOR.
     *  @param _loserStakeMultiplier The new loser stake multiplier value respect to DENOMINATOR.
     *  @param _loserAppealPeriodMultiplier The new loser appeal period multiplier respect to DENOMINATOR.
     */
    function changeMultipliers(
        uint256 _winnerStakeMultiplier,
        uint256 _loserStakeMultiplier,
        uint256 _loserAppealPeriodMultiplier
    ) external {
        require(msg.sender == governor, "Only the governor can execute this.");
        winnerStakeMultiplier = _winnerStakeMultiplier;
        loserStakeMultiplier = _loserStakeMultiplier;
        loserAppealPeriodMultiplier = _loserAppealPeriodMultiplier;
    }

    /** @dev Returns the sum of withdrawable amount. Although it's a nested loop, total iterations will be almost always less than 10. (Max number of rounds is 7 and it's very unlikely to have a contributor to contribute to more than 1 ruling option per round). Alternatively you can use Contribution events to calculate this off-chain.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The contributor for which to query.
     *  @param _contributedTo The array which includes ruling options to search for potential withdrawal. Caller can obtain this information using Contribution events.
     *  @return sum The total amount available to withdraw.
     */
    function getTotalWithdrawableAmount(
        uint256 _localDisputeID,
        address payable _contributor,
        uint256[] memory _contributedTo
    ) public view override returns (uint256 sum) {
        DisputeStruct storage dispute = disputes[_localDisputeID];
        if (!dispute.isRuled) return 0;
        uint256 finalRuling = dispute.ruling;

        uint256 noOfRounds = disputeIDtoRoundArray[_localDisputeID].length;
        for (uint256 roundNumber = 0; roundNumber < noOfRounds; roundNumber++) {
            Round storage round = disputeIDtoRoundArray[_localDisputeID][roundNumber];
            for (uint256 contributionNumber = 0; contributionNumber < _contributedTo.length; contributionNumber++) {
                uint256 ruling = _contributedTo[contributionNumber];

                sum += getWithdrawableAmount(round, _contributor, ruling, finalRuling);
            }
        }
    }

    /** @dev Returns stake multipliers.
     *  @return _winnerStakeMultiplier Winners stake multiplier.
     *  @return _loserStakeMultiplier Losers stake multiplier.
     *  @return _loserAppealPeriodMultiplier Multiplier for losers appeal period. The loser is given less time to fund its appeal to defend against last minute appeal funding attacks.
     *  @return _denominator Multiplier denominator in basis points.
     */
    function getMultipliers()
        external
        view
        override
        returns (
            uint256 _winnerStakeMultiplier,
            uint256 _loserStakeMultiplier,
            uint256 _loserAppealPeriodMultiplier,
            uint256 _denominator
        )
    {
        return (winnerStakeMultiplier, loserStakeMultiplier, loserAppealPeriodMultiplier, DENOMINATOR);
    }

    /** @dev Returns withdrawable amount for given parameters.
     *  @param _round The round number to calculate amount for.
     *  @param _contributor The contributor for which to query.
     *  @param _contributedTo The ruling option to search for potential withdrawal. Caller can obtain this information using Contribution events.
     *  @return amount The total amount available to withdraw.
     */
    function getWithdrawableAmount(
        Round storage _round,
        address _contributor,
        uint256 _contributedTo,
        uint256 _finalRuling
    ) internal view returns (uint256 amount) {
        if (!_round.hasPaid[_contributedTo]) {
            // Allow to reimburse if funding was unsuccessful for this ruling option.
            amount = _round.contributions[_contributor][_contributedTo];
        } else {
            // Funding was successful for this ruling option.
            if (_contributedTo == _finalRuling) {
                // This ruling option is the ultimate winner.
                amount = _round.paidFees[_contributedTo] > 0 ? (_round.contributions[_contributor][_contributedTo] * _round.feeRewards) / _round.paidFees[_contributedTo] : 0;
            } else if (_round.fundedRulings.length >= 1 && !_round.hasPaid[_finalRuling]) {
                // The ultimate winner was not funded in this round. In this case funded ruling option(s) wins by default. Prize is distributed among contributors of funded ruling option(s).
                amount = (_round.contributions[_contributor][_contributedTo] * _round.feeRewards) / (_round.paidFees[_round.fundedRulings[0]] + _round.paidFees[_round.fundedRulings[1]]);
            }
        }
    }

    /** @dev Reverts if appeal period has expired for given ruling option. It gives less time for funding appeal for losing ruling option (in the last round).
     *  Note that we don't check starting time, as arbitrator already check this. If user contributes before starting time it's effectively an early contibution for the next round.
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

        if (_currentRuling == _ruling) {
            require(block.timestamp < originalEnd, "Funding must be made within the appeal period.");
        } else {
            require(block.timestamp < (originalStart + ((originalEnd - originalStart) * loserAppealPeriodMultiplier) / DENOMINATOR), "Funding must be made within the appeal period.");
        }
    }

    /** @dev Retrieves appeal cost for each ruling. It extends the function with the same name on the arbitrator side by adding
     *  _ruling parameter because total to be raised depends on multipliers.
     *  @param _disputeID The dispute this function returns its appeal costs.
     *  @param _arbitratorExtraData Extra data for the arbitrator of prospective dispute.
     *  @param _ruling The ruling option which the caller wants to return the appeal cost for.
     *  @param _currentRuling The ruling option which the caller wants to return the appeal cost for.
     *  @return originalCost The original cost of appeal, decided by arbitrator.
     *  @return specificCost The specific cost of appeal, including appeal stakes of winner or loser.
     */
    function appealCost(
        uint256 _disputeID,
        bytes memory _arbitratorExtraData,
        uint256 _ruling,
        uint256 _currentRuling
    ) internal view returns (uint256 originalCost, uint256 specificCost) {
        uint256 multiplier;
        if (_ruling == _currentRuling || _currentRuling == 0) multiplier = winnerStakeMultiplier;
        else multiplier = loserStakeMultiplier;

        uint256 appealFee = arbitrator.appealCost(_disputeID, _arbitratorExtraData);
        return (appealFee, appealFee.addCap(appealFee.mulCap(multiplier) / DENOMINATOR));
    }
}
