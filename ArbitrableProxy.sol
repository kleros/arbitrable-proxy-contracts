
pragma solidity >=0.6;


/** @title Arbitrator
 *  Arbitrator abstract contract.
 *  When developing arbitrator contracts we need to:
 *  -Define the functions for dispute creation (createDispute) and appeal (appeal). Don't forget to store the arbitrated contract and the disputeID (which should be unique, may nbDisputes).
 *  -Define the functions for cost display (arbitrationCost and appealCost).
 *  -Allow giving rulings. For this a function must call arbitrable.rule(disputeID, ruling).
 */
interface IArbitrator {

    enum DisputeStatus {Waiting, Appealable, Solved}

    /** @dev To be emitted when a dispute is created.
     *  @param _disputeID ID of the dispute.
     *  @param _arbitrable The contract which created the dispute.
     */
    event DisputeCreation(uint indexed _disputeID, IArbitrable indexed _arbitrable);

    /** @dev To be emitted when a dispute can be appealed.
     *  @param _disputeID ID of the dispute.
     *  @param _arbitrable The contract which created the dispute.
     */
    event AppealPossible(uint indexed _disputeID, IArbitrable indexed _arbitrable);

    /** @dev To be emitted when the current ruling is appealed.
     *  @param _disputeID ID of the dispute.
     *  @param _arbitrable The contract which created the dispute.
     */
    event AppealDecision(uint indexed _disputeID, IArbitrable indexed _arbitrable);

    /** @dev Create a dispute. Must be called by the arbitrable contract.
     *  Must be paid at least arbitrationCost(_extraData).
     *  @param _choices Amount of choices the arbitrator can make in this dispute.
     *  @param _extraData Can be used to give additional info on the dispute to be created.
     *  @return disputeID ID of the dispute created.
     */
    function createDispute(uint _choices, bytes calldata _extraData) external payable returns(uint disputeID);

    /** @dev Compute the cost of arbitration. It is recommended not to increase it often, as it can be highly time and gas consuming for the arbitrated contracts to cope with fee augmentation.
     *  @param _extraData Can be used to give additional info on the dispute to be created.
     *  @return cost Amount to be paid.
     */
    function arbitrationCost(bytes calldata _extraData) external view returns(uint cost);

    /** @dev Appeal a ruling. Note that it has to be called before the arbitrator contract calls rule.
     *  @param _disputeID ID of the dispute to be appealed.
     *  @param _extraData Can be used to give extra info on the appeal.
     */
    function appeal(uint _disputeID, bytes calldata _extraData) external payable;

    /** @dev Compute the cost of appeal. It is recommended not to increase it often, as it can be higly time and gas consuming for the arbitrated contracts to cope with fee augmentation.
     *  @param _disputeID ID of the dispute to be appealed.
     *  @param _extraData Can be used to give additional info on the dispute to be created.
     *  @return cost Amount to be paid.
     */
    function appealCost(uint _disputeID, bytes calldata _extraData) external view returns(uint cost);

    /** @dev Compute the start and end of the dispute's current or next appeal period, if possible. If not known or appeal is impossible: should return (0, 0).
     *  @param _disputeID ID of the dispute.
     *  @return start The start of the period.
     *  @return end The end of the period.
     */
    function appealPeriod(uint _disputeID) external view returns(uint start, uint end);

    /** @dev Return the status of a dispute.
     *  @param _disputeID ID of the dispute to rule.
     *  @return status The status of the dispute.
     */
    function disputeStatus(uint _disputeID) external view returns(DisputeStatus status);

    /** @dev Return the current ruling of a dispute. This is useful for parties to know if they should appeal.
     *  @param _disputeID ID of the dispute.
     *  @return ruling The ruling which has been given or the one which will be given if there is no appeal.
     */
    function currentRuling(uint _disputeID) external view returns(uint ruling);

}



/** @title IArbitrable
 *  Arbitrable interface.
 *  When developing arbitrable contracts, we need to:
 *  -Define the action taken when a ruling is received by the contract.
 *  -Allow dispute creation. For this a function must call arbitrator.createDispute.value(_fee)(_choices,_extraData);
 */
interface IArbitrable {

    /** @dev To be raised when a ruling is given.
     *  @param _arbitrator The arbitrator giving the ruling.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling The ruling which was given.
     */
    event Ruling(IArbitrator indexed _arbitrator, uint indexed _disputeID, uint _ruling);

    /** @dev Give a ruling for a dispute. Must be called by the arbitrator.
     *  The purpose of this function is to ensure that the address calling it has the right to rule on the contract.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Not able/wanting to make a decision".
     */
    function rule(uint _disputeID, uint _ruling) external;
}



/**
 * @title CappedMath
 * @dev Math operations with caps for under and overflow.
 */
library CappedMath {
    uint constant private UINT_MAX = 2**256 - 1;

    /**
     * @dev Adds two unsigned integers, returns 2^256 - 1 on overflow.
     */
    function addCap(uint _a, uint _b) internal pure returns (uint) {
        uint c = _a + _b;
        return c >= _a ? c : UINT_MAX;
    }

    /**
     * @dev Subtracts two integers, returns 0 on underflow.
     */
    function subCap(uint _a, uint _b) internal pure returns (uint) {
        if (_b > _a)
            return 0;
        else
            return _a - _b;
    }

    /**
     * @dev Multiplies two unsigned integers, returns 2^256 - 1 on overflow.
     */
    function mulCap(uint _a, uint _b) internal pure returns (uint) {
        // Gas optimization: this is cheaper than requiring '_a' not being zero, but the
        // benefit is lost if '_b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-solidity/pull/522
        if (_a == 0)
            return 0;

        uint c = _a * _b;
        return c / _a == _b ? c : UINT_MAX;
    }
}


/**
 *  @title Interface that is implemented on resolve.kleros.io
 *  Sets a standard arbitrable contract implementation to provide a general purpose user interface.
 */
interface IDisputeResolver is IArbitrable, IEvidence {


    /** @dev To be raised inside fundAppeal function.
     *  @param localDisputeID The dispute id as in arbitrable contract.
     *  @param round Round code of the appeal. Starts from 0.
     *  @param ruling Indicates the ruling option which got the contribution.
     *  @param contributor Caller of fundAppeal function.
     *  @param amount Contribution amount.
     */
    event Contribution(uint indexed localDisputeID, uint indexed round, uint ruling, address indexed contributor, uint amount);

    /** @dev To be raised inside withdrawFeesAndRewards function.
     *  @param localDisputeID The dispute id as in arbitrable contract.
     *  @param round Round code of the appeal. Starts from 0.
     *  @param ruling Indicates the ruling option which got the contribution.
     *  @param contributor Caller of fundAppeal function.
     *  @param reward Total amount of deposits reimbursed plus rewards. This amount will be sent to contributor as an effect of calling withdrawFeesAndRewards function.
     */
    event Withdrawal(uint indexed localDisputeID, uint indexed round, uint ruling, address indexed contributor, uint reward);


    /** @dev Maps external (arbitrator side) dispute id to local (arbitrable) dispute id.
     *  @param _externalDisputeID Dispute id as in arbitrator side.
     *  @return localDisputeID Dispute id as in arbitrable contract.
     */
    function externalIDtoLocalID(uint _externalDisputeID) external returns (uint localDisputeID);

    /** @dev Returns number of possible ruling options. Valid rulings are [0, return value].
     *  @param _localDisputeID Dispute id as in arbitrable contract.
     */
    function numberOfRulingOptions(uint _localDisputeID) external view returns (uint numberOfRulingOptions);

    /** @dev Allows to submit evidence for a given dispute.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _evidenceURI Link to evidence.
     */
    function submitEvidence(uint _localDisputeID, string calldata _evidenceURI) external;

    /** @dev TRUSTED. Manages contributions and calls appeal function of the specified arbitrator to appeal a dispute. This function lets appeals be crowdfunded.
        Note that we don’t need to check that msg.value is enough to pay arbitration fees as it’s the responsibility of the arbitrator contract.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _ruling The side to which the caller wants to contribute.
     */
    function fundAppeal(uint _localDisputeID, uint _ruling) external payable returns (bool fullyFunded);

    /** @dev Returns stake multipliers.
     *  @return winner Winners stake multiplier.
     *  @return loser Losers stake multiplier.
     *  @return shared Multiplier when it's tied.
     *  @return divisor Multiplier divisor.
     */
    function getMultipliers() external view returns(uint winner, uint loser, uint shared, uint divisor);

    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _roundNumber The number of the round caller wants to withdraw from.
     *  @param _ruling A ruling option that the caller wannts to withdraw fees and rewards related to it.
     */
    function withdrawFeesAndRewards(uint _localDisputeID, address payable _contributor, uint _roundNumber, uint _ruling) external returns (uint reward);

    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved. For multiple ruling options at once.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _roundNumber The number of the round caller wants to withdraw from.
     *  @param _contributedTo Rulings that received contributions from contributor.
     */
    function withdrawFeesAndRewardsForMultipleRulings(uint _localDisputeID, address payable _contributor, uint _roundNumber, uint[] memory _contributedTo) external;


    /** @dev Allows to withdraw any rewards or reimbursable fees after the dispute gets resolved. For multiple rulings options and for all rounds at once.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _contributedTo Rulings that received contributions from contributor.
     */
    function withdrawFeesAndRewardsForAllRounds(uint _localDisputeID, address payable _contributor, uint[] memory _contributedTo) external;

}

/**
 *  @title ArbitrableProxy
 *  A general purpose arbitrable contract. Supports non-binary rulings.
 */
contract ArbitrableProxy is IDisputeResolver {

    string public constant VERSION = '1.0.0';

    using CappedMath for uint; // Operations bounded between 0 and 2**256 - 1.

    event Contribution(uint indexed localDisputeID, uint indexed round, uint ruling, address indexed contributor, uint amount);
    event Withdrawal(uint indexed localDisputeID, uint indexed round, uint ruling, address indexed contributor, uint reward);
    event SideFunded(uint indexed localDisputeID, uint indexed round, uint indexed ruling);

    struct Round {
        mapping(uint => uint) paidFees; // Tracks the fees paid by each side in this round.
        mapping(uint => bool) hasPaid; // True when the side has fully paid its fee. False otherwise.
        mapping(address => mapping(uint => uint)) contributions; // Maps contributors to their contributions for each side.
        uint256 feeRewards; // Sum of reimbursable appeal fees available to the parties that made contributions to the side that ultimately wins a dispute.
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

    address public governor = msg.sender;
    IArbitrator public arbitrator;

    // The required fee stake that a party must pay depends on who won the previous round and is proportional to the arbitration cost such that the fee stake for a round is stake multiplier * arbitration cost for that round.
    // Multipliers are in basis points.
    uint public winnerStakeMultiplier; // Multiplier for calculating the fee stake paid by the party that won the previous round.
    uint public loserStakeMultiplier; // Multiplier for calculating the fee stake paid by the party that lost the previous round.
    uint public sharedStakeMultiplier; // Multiplier for calculating the fee stake that must be paid in the case where there isn't a winner and loser (e.g. when it's the first round or the arbitrator ruled "refused to rule"/"could not rule").
    uint public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    DisputeStruct[] public disputes;
    mapping(uint => uint) public override externalIDtoLocalID; // Maps external (arbitrator side) dispute ids to local dispute ids.
    mapping(uint => Round[]) public disputeIDtoRoundArray; // Maps dispute ids round arrays.

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

    /** @dev TRUSTED. Calls createDispute function of the specified arbitrator to create a dispute.
        Note that we don’t need to check that msg.value is enough to pay arbitration fees as it’s the responsibility of the arbitrator contract.
     *  @param _arbitratorExtraData Extra data for the arbitrator of prospective dispute.
     *  @param _metaevidenceURI Link to metaevidence of prospective dispute.
     *  @param _numberOfChoices Number of currentRuling options.
     *  @return disputeID Dispute id (on arbitrator side) of the dispute created.
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

        disputeIDtoRoundArray[localDisputeID].push(
            Round({
            feeRewards: 0,
            fundedSides: new uint[](0),
            appealFee: 0
            })
        );

        emit MetaEvidence(localDisputeID, _metaevidenceURI);
        emit Dispute(arbitrator, disputeID, localDisputeID, localDisputeID);
    }

    /** @dev Returns number of possible currentRuling options. Valid rulings are [0, return value].
     *  @param _localDisputeID Dispute id as in arbitrable contract.
     */
    function numberOfRulingOptions(uint _localDisputeID) external view override returns (uint numberOfRulingOptions){
        numberOfRulingOptions = disputes[_localDisputeID].numberOfChoices;
    }


    /** @dev TRUSTED. Manages contributions and calls appeal function of the specified arbitrator to appeal a dispute. This function lets appeals be crowdfunded.
        Note that we don’t need to check that msg.value is enough to pay arbitration fees as it’s the responsibility of the arbitrator contract.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _ruling The side to which the caller wants to contribute.
     *  @param fullyFunded Whether _ruling was fully funded after the call.
     */
    function fundAppeal(uint _localDisputeID, uint _ruling) external override payable returns (bool fullyFunded){
        DisputeStruct storage dispute = disputes[_localDisputeID];
        require(_ruling <= dispute.numberOfChoices && _ruling != 0, "There is no such side to fund.");

        (uint appealPeriodStart, uint appealPeriodEnd) = arbitrator.appealPeriod(dispute.disputeIDOnArbitratorSide);
        require(now >= appealPeriodStart && now < appealPeriodEnd, "Funding must be made within the appeal period.");

        uint winner = arbitrator.currentRuling(dispute.disputeIDOnArbitratorSide);
        uint multiplier;

        if (winner == _ruling){
            multiplier = winnerStakeMultiplier;
        } else if (winner == 0){
            multiplier = sharedStakeMultiplier;
        } else {
            multiplier = loserStakeMultiplier;
            require((_ruling==winner) || (now-appealPeriodStart < (appealPeriodEnd-appealPeriodStart)/2), "The loser must contribute during the first half of the appeal period.");
        }

        uint appealCost = arbitrator.appealCost(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);
        uint totalCost = appealCost.addCap(appealCost.mulCap(multiplier) / MULTIPLIER_DIVISOR);

        Round[] storage rounds = disputeIDtoRoundArray[_localDisputeID];
        Round storage lastRound = disputeIDtoRoundArray[_localDisputeID][rounds.length - 1];
        require(!lastRound.hasPaid[_ruling], "Appeal fee has already been paid.");
        require(msg.value > 0, "Can't contribute zero");

        uint contribution = totalCost.subCap(lastRound.paidFees[_ruling]) > msg.value ? msg.value : totalCost.subCap(lastRound.paidFees[_ruling]);
        emit Contribution(_localDisputeID, rounds.length - 1, _ruling, msg.sender, contribution);

        lastRound.contributions[msg.sender][uint(_ruling)] += contribution;
        lastRound.paidFees[uint(_ruling)] += contribution;

        if (lastRound.paidFees[_ruling] >= totalCost) {
            lastRound.feeRewards += lastRound.paidFees[_ruling];
            lastRound.fundedSides.push(_ruling);
            lastRound.hasPaid[_ruling] = true;
            emit SideFunded(_localDisputeID, rounds.length - 1, _ruling);
        }

        if (lastRound.fundedSides.length > 1) {
            // At least two sides are fully funded.
            rounds.push(Round({
              feeRewards: 0,
              fundedSides: new uint[](0),
              appealFee: 0
            }));

            lastRound.feeRewards = lastRound.feeRewards.subCap(appealCost);
            lastRound.appealFee = appealCost;
            arbitrator.appeal.value(appealCost)(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);
        }

        msg.sender.transfer(msg.value.subCap(contribution)); // Sending extra value back to contributor.

        return lastRound.hasPaid[_ruling];
    }


    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _roundNumber The number of the round caller wants to withdraw from.
     *  @param _ruling A currentRuling option that the caller wannts to withdraw fees and rewards related to it.
     *  @return reward Reward amount that is to be withdrawn. Might be zero if arguments are not qualifying for a reward or reimbursement, or it might be withdrawn already.
     */
    function withdrawFeesAndRewards(uint _localDisputeID, address payable _contributor, uint _roundNumber, uint _ruling) public override returns (uint reward) {
        DisputeStruct storage dispute = disputes[_localDisputeID];

        Round storage round = disputeIDtoRoundArray[_localDisputeID][_roundNumber];
        uint8 currentRuling = uint8(dispute.ruling);

        require(dispute.isRuled, "The dispute should be solved");
        uint reward;

        if (!round.hasPaid[_ruling]) {
            // Allow to reimburse if funding was unsuccessful.
            reward = round.contributions[_contributor][_ruling];
            _contributor.send(reward); // User is responsible for accepting the reward.

        } else if (currentRuling == 0 || !round.hasPaid[currentRuling]) {
            // Reimburse unspent fees proportionally if there is no winner and loser.
            reward = round.appealFee > 0 // Means appeal took place.
                ? (round.contributions[_contributor][_ruling] * round.feeRewards) / (round.feeRewards + round.appealFee)
                : 0;

                _contributor.send(reward); // User is responsible for accepting the reward.


        } else if(currentRuling == _ruling) {
            // Reward the winner.
            reward = round.paidFees[currentRuling] > 0
                ? (round.contributions[_contributor][_ruling] * round.feeRewards) / round.paidFees[currentRuling]
                : 0;
                _contributor.send(reward); // User is responsible for accepting the reward.
          }
          round.contributions[_contributor][currentRuling] = 0;

          emit Withdrawal(_localDisputeID, _roundNumber, _ruling, _contributor, reward);
    }

    /** @dev Allows to withdraw any reimbursable fees or rewards after the dispute gets solved. For multiple currentRuling options at once.
     *  @param _localDisputeID Index of the dispute in disputes array.
     *  @param _contributor The address to withdraw its rewards.
     *  @param _roundNumber The number of the round caller wants to withdraw from.
     *  @param _contributedTo Rulings that received contributions from contributor.
     */
    function withdrawFeesAndRewardsForMultipleRulings(uint _localDisputeID, address payable _contributor, uint _roundNumber, uint[] memory _contributedTo) public override {
        Round storage round = disputeIDtoRoundArray[_localDisputeID][_roundNumber];
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
        for (uint roundNumber = 0; roundNumber < disputeIDtoRoundArray[_localDisputeID].length; roundNumber++) {
            withdrawFeesAndRewardsForMultipleRulings(_localDisputeID, _contributor, roundNumber, _contributedTo);
        }
    }

    /** @dev To be called by the arbitrator of the dispute, to declare winning side.
     *  @param _externalDisputeID ID of the dispute in arbitrator contract.
     *  @param _ruling The currentRuling choice of the arbitration.
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
        // If one side paid its fees, the currentRuling is in its favor. Note that if any other side had also paid, an appeal would have been created.
        if (lastRound.fundedSides.length == 1) {
            dispute.ruling = lastRound.fundedSides[0];
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

    /** @dev Gets the information of a round of a dispute.
     *  @param _localDisputeID ID of the dispute.
     *  @param _round The round to be queried.
     */
    function getRoundInfo(uint _localDisputeID, uint _round)
        external
        view
        returns (
            bool appealed,
            uint[] memory paidFees,
            bool[] memory hasPaid,
            uint feeRewards,
            uint[] memory fundedSides,
            uint appealFee
        )
    {
        Round storage round = disputeIDtoRoundArray[_localDisputeID][_round];
        fundedSides = round.fundedSides;

        paidFees = new uint[](round.fundedSides.length);
        hasPaid = new bool[](round.fundedSides.length);

        for (uint i = 0; i < round.fundedSides.length; i++) {
            paidFees[i] = round.paidFees[round.fundedSides[i]];
            hasPaid[i] = round.hasPaid[round.fundedSides[i]];
        }

        appealed = _round != (disputeIDtoRoundArray[_localDisputeID].length - 1);
        feeRewards = round.feeRewards;
        appealFee = round.appealFee;
    }


    /** @dev Gets the information of a round of a dispute.
     *  @param _localDisputeID ID of the dispute.
     *  @param _round The round to be queried.
     */
    function getContributions(
    uint _localDisputeID,
    uint _round,
    address _contributor
    ) public view returns(
        uint[] memory fundedSides,
        uint[] memory contributions
        )
    {
        Round storage round = disputeIDtoRoundArray[_localDisputeID][_round];
        fundedSides = round.fundedSides;
        contributions = new uint[](round.fundedSides.length);
        for (uint i = 0; i < contributions.length; i++) {
            contributions[i] = round.contributions[_contributor][fundedSides[i]];
        }
    }


    /** @dev Gets the crowdfunding information of a last round of a dispute.
     *  @param _localDisputeID ID of the dispute.
     *  @param _contributor Address of crowdfunding participant to get details of.
     */
    function crowdfundingStatus(
    uint _localDisputeID,
    address _contributor
    ) public view returns(
        uint[] memory paidFees,
        bool[] memory hasPaid,
        uint feeRewards,
        uint[] memory contributions,
        uint[] memory fundedSides
        )
    {
        Round[] storage rounds = disputeIDtoRoundArray[_localDisputeID];
        Round storage round = disputeIDtoRoundArray[_localDisputeID][rounds.length -1];
        fundedSides = round.fundedSides;
        contributions = new uint[](round.fundedSides.length);

        paidFees = new uint[](round.fundedSides.length);
        hasPaid = new bool[](round.fundedSides.length);
        feeRewards = round.feeRewards;

        for (uint i = 0; i < round.fundedSides.length; i++) {
            paidFees[i] = round.paidFees[round.fundedSides[i]];
            hasPaid[i] = round.hasPaid[round.fundedSides[i]];
            contributions[i] = round.contributions[_contributor][fundedSides[i]];
        }
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
