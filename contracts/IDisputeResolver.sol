// SPDX-License-Identifier: MIT

/**
 *  @authors: [@ferittuncer]
 *  @reviewers: [@mtsalenc]
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity >=0.7;

import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";

/**
 *  @title This is a common interface for apps to interact with disputes’ standard operations.
 *  Sets a standard arbitrable contract implementation to provide a general purpose user interface.
 */
abstract contract IDisputeResolver is IArbitrable, IEvidence {
    string public constant VERSION = "1.0.0";

    /** @dev Raised when a contribution is made, inside fundAppeal function.
     *  @param localDisputeID The dispute id as in the arbitrable contract.
     *  @param round The round number the contribution was made to.
     *  @param ruling Indicates the ruling option which got the contribution.
     *  @param contributor Caller of fundAppeal function.
     *  @param amount Contribution amount.
     */
    event Contribution(uint256 indexed localDisputeID, uint256 indexed round, uint256 ruling, address indexed contributor, uint256 amount);

    /** @dev Raised when a contributor withdraws non-zero value.
     *  @param localDisputeID The dispute id as in arbitrable contract.
     *  @param round The round number the withdrawal was made from.
     *  @param ruling Indicates the ruling option which contributor gets rewards from.
     *  @param contributor The beneficiary of withdrawal.
     *  @param reward Total amount of deposits reimbursed plus rewards. This amount will be sent to contributor as an effect of calling withdrawFeesAndRewards function.
     */
    event Withdrawal(uint256 indexed localDisputeID, uint256 indexed round, uint256 ruling, address indexed contributor, uint256 reward);

    /** @dev To be raised when a ruling option is fully funded for appeal.
     *  @param localDisputeID The dispute id as in arbitrable contract.
     *  @param round Round code of the appeal. Starts from 0.
     *  @param ruling THe ruling option which just got fully funded.
     */
    event RulingFunded(uint256 indexed localDisputeID, uint256 indexed round, uint256 indexed ruling);

    /** @dev Maps external (arbitrator side) dispute id to local (arbitrable) dispute id. This is necessary to obtain local dispute data by arbitrators id.
     *  @param _externalDisputeID Dispute id as in arbitrator side.
     *  @return localDisputeID Dispute id as in arbitrable contract.
     */
    function externalIDtoLocalID(uint256 _externalDisputeID) external virtual returns (uint256 localDisputeID);

    /** @dev Returns number of possible ruling options. Valid rulings are [0, return value].
     *  @param _localDisputeID Dispute id as in arbitrable contract.
     *  @return count The number of ruling options.
     */
    function numberOfRulingOptions(uint256 _localDisputeID) external view virtual returns (uint256 count);

    /** @dev Allows to submit evidence for a given dispute.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _evidenceURI Link to evidence.
     */
    function submitEvidence(uint256 _localDisputeID, string calldata _evidenceURI) external virtual;

    /** @dev TRUSTED. Manages contributions and calls appeal function of the specified arbitrator to appeal a dispute. This function lets appeals be crowdfunded.
        Note that we don’t need to check that msg.value is enough to pay arbitration fees as it’s the responsibility of the arbitrator contract.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _ruling The ruling option to which the caller wants to contribute.
     *  @return fullyFunded True if the ruling option got fully funded as a result of this contribution.
     */
    function fundAppeal(uint256 _localDisputeID, uint256 _ruling) external payable virtual returns (bool fullyFunded);

    /** @dev Returns stake multipliers.
     *  @return winnerStakeMultiplier Winners stake multiplier.
     *  @return loserStakeMultiplier Losers stake multiplier.
     *  @return loserAppealPeriodMultiplier Losers appeal period multiplier. The loser is given less time to fund its appeal to defend against last minute appeal funding attacks.
     *  @return divisor Multiplier divisor in basis points.
     */
    function getMultipliers()
        external
        view
        virtual
        returns (
            uint256 winnerStakeMultiplier,
            uint256 loserStakeMultiplier,
            uint256 loserAppealPeriodMultiplier,
            uint256 divisor
        );

    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _roundNumber The number of the round caller wants to withdraw from.
     *  @param _ruling A ruling option that the caller wants to withdraw fees and rewards related to it.
     *  @return sum The reward that is going to be paid as a result of this function call, if it's not zero.
     */
    function withdrawFeesAndRewards(
        uint256 _localDisputeID,
        address payable _contributor,
        uint256 _roundNumber,
        uint256 _ruling
    ) external virtual returns (uint256 sum);

    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved. For multiple ruling options at once.
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
    ) external virtual;

    /** @dev Allows to withdraw any rewards or reimbursable fees after the dispute gets resolved. For multiple rulings options and for all rounds at once.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _contributedTo Rulings that received contributions from contributor.
     */
    function withdrawFeesAndRewardsForAllRounds(
        uint256 _localDisputeID,
        address payable _contributor,
        uint256[] memory _contributedTo
    ) external virtual;

    /** @dev Returns the sum of withdrawable amount.
     *  @param _localDisputeID The ID of the associated question.
     *  @param _contributor The contributor for which to query.
     *  @param _contributedTo Ruling options to look for potential withdrawals.
     *  @return sum The total amount available to withdraw.
     */
    function getTotalWithdrawableAmount(
        uint256 _localDisputeID,
        address payable _contributor,
        uint256[] memory _contributedTo
    ) public view virtual returns (uint256 sum);
}
