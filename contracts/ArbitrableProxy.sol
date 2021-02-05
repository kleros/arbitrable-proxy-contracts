// SPDX-License-Identifier: MIT

/**
 *  @authors: [@ferittuncer]
 *  @reviewers: [@fnanni-0*, @unknownunknown1*, @mtsalenc]
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity >=0.7;

import "./IDisputeResolver.sol";
import "@kleros/ethereum-libraries/contracts/CappedMath.sol";

/**
 *  @title ArbitrableProxy
 *  A general purpose arbitrable contract. Supports non-binary rulings.
 */
contract ArbitrableProxy is IDisputeResolver {
    using CappedMath for uint256; // Operations bounded between 0 and 2**256 - 2. Note the 0 is reserver for invalid / refused to rule.

    uint256 public constant MAX_NO_OF_CHOICES = (2**256) - 2;

    struct Round {
        mapping(uint256 => uint256) paidFees; // Tracks the fees paid for each ruling option in this round.
        mapping(uint256 => bool) hasPaid; // True if this ruling option was fully funded; false otherwise.
        mapping(address => mapping(uint256 => uint256)) contributions; // Maps contributors to their contributions for each side.
        uint256 feeRewards; // Sum of reimbursable appeal fees available to the parties that made contributions to the ruling that ultimately wins a dispute.
        uint256[] fundedRulings; // Stores the ruling options that are fully funded.
    }

    struct DisputeStruct {
        bytes arbitratorExtraData;
        bool isRuled;
        uint256 ruling;
        uint256 disputeIDOnArbitratorSide;
        uint256 numberOfRulingOptions;
    }

    address public governor = msg.sender;
    IArbitrator public arbitrator;

    // The required fee stake that a party must pay depends on who won the previous round and is proportional to the arbitration cost such that the fee stake for a round is stake multiplier * arbitration cost for that round.
    uint256 public winnerStakeMultiplier = 10000; // Multiplier of the arbitration cost that the winner has to pay as fee stake for a round in basis points. Default is 1x of appeal fee.
    uint256 public loserStakeMultiplier = 20000; // Multiplier of the arbitration cost that the loser has to pay as fee stake for a round in basis points. Default is 2x of appeal fee.
    uint256 public loserAppealPeriodMultiplier = 5000; // Multiplier of the appeal period for losers (any other ruling options) in basis points. Default is 1/2 of original appeal period.
    uint256 public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    DisputeStruct[] public disputes;
    mapping(uint256 => uint256) public override externalIDtoLocalID; // Maps external (arbitrator side) dispute ids to local dispute ids.
    mapping(uint256 => Round[]) public disputeIDtoRoundArray; // Maps dispute ids to round arrays.

    /** @dev Constructor
     *  @param _arbitrator Target global arbitrator for any disputes.
     */
    constructor(IArbitrator _arbitrator) {
        arbitrator = _arbitrator;
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
        if (_numberOfRulingOptions == 0)
            _numberOfRulingOptions = MAX_NO_OF_CHOICES;

        disputeID = arbitrator.createDispute{value: msg.value}(
            _numberOfRulingOptions,
            _arbitratorExtraData
        );

        disputes.push(
            DisputeStruct({
                arbitratorExtraData: _arbitratorExtraData,
                isRuled: false,
                ruling: 0,
                disputeIDOnArbitratorSide: disputeID,
                numberOfRulingOptions: _numberOfRulingOptions
            })
        );

        uint256 localDisputeID = disputes.length - 1;
        externalIDtoLocalID[disputeID] = localDisputeID;

        disputeIDtoRoundArray[localDisputeID].push();

        emit MetaEvidence(localDisputeID, _metaevidenceURI);
        emit Dispute(arbitrator, disputeID, localDisputeID, localDisputeID);
    }

    /** @dev Returns number of possible ruling options. Valid rulings are [0, return value].
     *  @param _localDisputeID Dispute id as in arbitrable contract.
     *  @return count Number of possible ruling options.
     */
    function numberOfRulingOptions(uint256 _localDisputeID)
        external
        view
        override
        returns (uint256 count)
    {
        count = disputes[_localDisputeID].numberOfRulingOptions;
    }

    /** @dev TRUSTED. Manages contributions and calls appeal function of the specified arbitrator to appeal a dispute. This function lets appeals be crowdfunded.
        Note that we don’t need to check that msg.value is enough to pay arbitration fees as it’s the responsibility of the arbitrator contract.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _ruling The ruling to which the caller wants to contribute.
     *  @return fullyFunded Whether _ruling was fully funded after the call.
     */
    function fundAppeal(uint256 _localDisputeID, uint256 _ruling)
        external
        payable
        override
        returns (bool fullyFunded)
    {
        DisputeStruct storage dispute = disputes[_localDisputeID];
        require(
            _ruling <= dispute.numberOfRulingOptions,
            "There is no such ruling to fund."
        );

        (uint256 appealPeriodStart, uint256 appealPeriodEnd) =
            appealPeriod(_localDisputeID, _ruling);
        require(
            block.timestamp >= appealPeriodStart &&
                block.timestamp < appealPeriodEnd,
            "Funding must be made within the appeal period."
        );

        uint256 totalCost = appealCost(_localDisputeID, _ruling);

        Round[] storage rounds = disputeIDtoRoundArray[_localDisputeID];
        Round storage lastRound = rounds[rounds.length - 1];
        require(
            !lastRound.hasPaid[_ruling],
            "Appeal fee has already been paid."
        );
        uint256 paidFeesInLastRound = lastRound.paidFees[_ruling];

        uint256 contribution =
            totalCost.subCap(paidFeesInLastRound) > msg.value
                ? msg.value
                : totalCost.subCap(paidFeesInLastRound);
        emit Contribution(
            _localDisputeID,
            rounds.length - 1,
            _ruling,
            msg.sender,
            contribution
        );

        lastRound.contributions[msg.sender][_ruling] += contribution;
        lastRound.paidFees[_ruling] += contribution;
        paidFeesInLastRound = lastRound.paidFees[_ruling];

        if (paidFeesInLastRound >= totalCost) {
            lastRound.feeRewards += paidFeesInLastRound;
            lastRound.fundedRulings.push(_ruling);
            lastRound.hasPaid[_ruling] = true;
            emit RulingFunded(_localDisputeID, rounds.length - 1, _ruling);
        }

        uint256 appealFee =
            arbitrator.appealCost(
                dispute.disputeIDOnArbitratorSide,
                dispute.arbitratorExtraData
            );

        if (lastRound.fundedRulings.length > 1) {
            // At least two ruling options are fully funded.
            rounds.push();

            lastRound.feeRewards = lastRound.feeRewards.subCap(appealFee);
            arbitrator.appeal{value: appealFee}(
                dispute.disputeIDOnArbitratorSide,
                dispute.arbitratorExtraData
            );
        }

        msg.sender.transfer(msg.value.subCap(contribution)); // Sending extra value back to contributor.

        return lastRound.hasPaid[_ruling];
    }

    /** @dev Retrieves appeal period for each ruling. It extends the function with the same name on the arbitrator by also requiring the _ruling parameter. This is because the arbitrable doesn't give losers of previous round as much time as the winner to avoid last-minute funding attacks.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _ruling The ruling option which the caller wants to learn about its appeal period.
     */
    function appealPeriod(uint256 _localDisputeID, uint256 _ruling)
        internal
        view
        returns (uint256 start, uint256 end)
    {
        DisputeStruct storage dispute = disputes[_localDisputeID];

        (uint256 originalStart, uint256 originalEnd) =
            arbitrator.appealPeriod(dispute.disputeIDOnArbitratorSide);

        if (
            _ruling ==
            arbitrator.currentRuling(dispute.disputeIDOnArbitratorSide)
        ) return (originalStart, originalEnd);
        else
            return (
                originalStart,
                ((originalStart + originalEnd) * MULTIPLIER_DIVISOR) /
                    loserAppealPeriodMultiplier
            );
    }

    /** @dev Retrieves appeal cost for each ruling. It extends the function with the same name on the arbitrator side by adding
     *  _ruling parameter because total to be raised depends on multipliers.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _ruling The ruling option which the caller wants to learn about its appeal cost.
     */
    function appealCost(uint256 _localDisputeID, uint256 _ruling)
        internal
        view
        returns (uint256)
    {
        DisputeStruct storage dispute = disputes[_localDisputeID];

        uint256 multiplier;

        if (
            _ruling ==
            arbitrator.currentRuling(dispute.disputeIDOnArbitratorSide)
        ) multiplier = winnerStakeMultiplier;
        else multiplier = loserStakeMultiplier;

        uint256 appealFee =
            arbitrator.appealCost(
                dispute.disputeIDOnArbitratorSide,
                dispute.arbitratorExtraData
            );
        return
            appealFee.addCap(appealFee.mulCap(multiplier) / MULTIPLIER_DIVISOR);
    }

    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _roundNumber The number of the round caller wants to withdraw from.
     *  @param _ruling The ruling option that the caller wants to withdraw fees and rewards related to it.
     *  @return sum Reward amount that is to be withdrawn. Might be zero if arguments are not qualifying for a reward or reimbursement, or it might be withdrawn already.
     */
    function withdrawFeesAndRewards(
        uint256 _localDisputeID,
        address payable _contributor,
        uint256 _roundNumber,
        uint256 _ruling
    ) public override returns (uint256 sum) {
        DisputeStruct storage dispute = disputes[_localDisputeID];

        Round storage round =
            disputeIDtoRoundArray[_localDisputeID][_roundNumber];

        require(dispute.isRuled, "The dispute should be solved");

        if (!round.hasPaid[_ruling]) {
            // Allow to reimburse if funding was unsuccessful for this ruling option.
            sum += round.contributions[_contributor][_ruling];
        } else {
            // Funding was successful for this ruling option.
            if (_ruling == dispute.ruling) {
                // This ruling option is the ultimate winner.
                uint256 paidFees = round.paidFees[_ruling];
                sum += paidFees > 0
                    ? (round.contributions[_contributor][_ruling] *
                        round.feeRewards) / paidFees
                    : 0;
            } else if (
                round.fundedRulings.length >= 1 &&
                !round.hasPaid[dispute.ruling]
            ) {
                // The ultimate winner was not funded in this round. In this case funded ruling option(s) wins by default. Prize is distributed among contributors of funded ruling option(s).
                sum +=
                    (round.contributions[_contributor][_ruling] *
                        round.feeRewards) /
                    (round.paidFees[round.fundedRulings[0]] +
                        round.paidFees[round.fundedRulings[1]]);
            }
        }

        round.contributions[_contributor][_ruling] = 0;
        if (sum != 0) {
            _contributor.send(sum); // User is responsible for accepting the reward.
            emit Withdrawal(
                _localDisputeID,
                _roundNumber,
                _ruling,
                _contributor,
                sum
            );
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
        for (
            uint256 contributionNumber = 0;
            contributionNumber < contributionArrayLength;
            contributionNumber++
        ) {
            withdrawFeesAndRewards(
                _localDisputeID,
                _contributor,
                _roundNumber,
                _contributedTo[contributionNumber]
            );
        }
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
            withdrawFeesAndRewardsForMultipleRulings(
                _localDisputeID,
                _contributor,
                roundNumber,
                _contributedTo
            );
        }
    }

    /** @dev Returns the sum of withdrawable amount. Although it's a nested loop, total iterations will be almost always less than 10. (Max number of rounds is 7 and it's very unlikely to have a contributor to contribute to more than 1 ruling option per round). Alternatively you can use Contribution events to calculate this off-chain.
     *  @param _localDisputeID The ID of the associated question.
     *  @param _contributor The contributor for which to query.
     *  @param _contributedTo The array which includes ruling options to search for potential withdrawal. Caller can obtain this information using Contribution events.
     *  @return sum The total amount available to withdraw.
     */
    function getTotalWithdrawableAmount(
        uint256 _localDisputeID,
        address payable _contributor,
        uint256[] memory _contributedTo
    ) public view override returns (uint256 sum) {
        uint256 noOfRounds = disputeIDtoRoundArray[_localDisputeID].length;
        for (uint256 roundNumber = 0; roundNumber < noOfRounds; roundNumber++) {
            for (
                uint256 contributionNumber = 0;
                contributionNumber < _contributedTo.length;
                contributionNumber++
            ) {
                DisputeStruct storage dispute = disputes[_localDisputeID];

                Round storage round =
                    disputeIDtoRoundArray[_localDisputeID][roundNumber];
                uint256 finalRuling = dispute.ruling;
                uint256 ruling = _contributedTo[contributionNumber];
                require(dispute.isRuled, "The dispute should be solved");

                if (!round.hasPaid[ruling]) {
                    // Allow to reimburse if funding was unsuccessful for this ruling option.
                    sum += round.contributions[_contributor][ruling];
                } else {
                    //Funding was successful for this ruling option.
                    if (ruling == finalRuling) {
                        // This ruling option is the ultimate winner.
                        sum += round.paidFees[ruling] > 0
                            ? (round.contributions[_contributor][ruling] *
                                round.feeRewards) / round.paidFees[ruling]
                            : 0;
                    } else if (
                        round.fundedRulings.length >= 1 &&
                        !round.hasPaid[finalRuling]
                    ) {
                        // The ultimate winner was not funded in this round. In this case funded ruling option(s) wins by default. Prize is distributed among contributors of funded ruling option(s).
                        sum +=
                            (round.contributions[_contributor][ruling] *
                                round.feeRewards) /
                            (round.paidFees[round.fundedRulings[0]] +
                                round.paidFees[round.fundedRulings[1]]);
                    }
                }
            }
        }
        return sum;
    }

    /** @dev To be called by the arbitrator of the dispute, to declare winning ruling.
     *  @param _externalDisputeID ID of the dispute in arbitrator contract.
     *  @param _ruling The ruling choice of the arbitration.
     */
    function rule(uint256 _externalDisputeID, uint256 _ruling)
        external
        override
    {
        uint256 _localDisputeID = externalIDtoLocalID[_externalDisputeID];
        DisputeStruct storage dispute = disputes[_localDisputeID];
        require(
            msg.sender == address(arbitrator),
            "Only the arbitrator can execute this."
        );
        require(_ruling <= dispute.numberOfRulingOptions, "Invalid ruling.");
        require(
            dispute.isRuled == false,
            "This dispute has been ruled already."
        );

        dispute.isRuled = true;
        dispute.ruling = _ruling;

        Round[] storage rounds = disputeIDtoRoundArray[_localDisputeID];
        Round storage lastRound =
            disputeIDtoRoundArray[_localDisputeID][rounds.length - 1];
        // If only one ruling option is funded, it wins by default. Note that if any other ruling had funded, an appeal would have been created.
        if (lastRound.fundedRulings.length == 1) {
            dispute.ruling = lastRound.fundedRulings[0];
        }

        emit Ruling(
            IArbitrator(msg.sender),
            _externalDisputeID,
            uint256(dispute.ruling)
        );
    }

    /** @dev Allows to submit evidence for a given dispute.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _evidenceURI Link to evidence.
     */
    function submitEvidence(
        uint256 _localDisputeID,
        string calldata _evidenceURI
    ) external override {
        DisputeStruct storage dispute = disputes[_localDisputeID];
        require(
            dispute.isRuled == false,
            "Cannot submit evidence to a resolved dispute."
        );

        emit Evidence(arbitrator, _localDisputeID, msg.sender, _evidenceURI);
    }

    /** @dev Changes governor.
     *  @param _newGovernor The address of the new governor.
     */
    function setGovernor(address _newGovernor) external {
        require(msg.sender == governor, "Only the governor can execute this.");
        governor = _newGovernor;
    }

    /** @dev Changes the proportion of appeal fees that must be paid by winner.
     *  @param _winnerStakeMultiplier The new winner stake multiplier value respect to MULTIPLIER_DIVISOR.
     *  @param _loserStakeMultiplier The new loser stake multiplier value respect to MULTIPLIER_DIVISOR.
     *  @param _loserAppealPeriodMultiplier The new loser appeal period multiplier respect to MULTIPLIER_DIVISOR.
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

    /** @dev Returns stake multipliers.
     *  @return _winnerStakeMultiplier Winners stake multiplier.
     *  @return _loserStakeMultiplier Losers stake multiplier.
     *  @return _loserAppealPeriodMultiplier Multiplier for losers appeal period. The loser is given less time to fund its appeal to defend against last minute appeal funding attacks.
     *  @return divisor Multiplier divisor in basis points.
     */
    function getMultipliers()
        external
        view
        override
        returns (
            uint256 _winnerStakeMultiplier,
            uint256 _loserStakeMultiplier,
            uint256 _loserAppealPeriodMultiplier,
            uint256 divisor
        )
    {
        return (
            winnerStakeMultiplier,
            loserStakeMultiplier,
            loserAppealPeriodMultiplier,
            MULTIPLIER_DIVISOR
        );
    }
}
