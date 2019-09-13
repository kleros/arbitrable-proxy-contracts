pragma solidity >=0.5 <0.6.0;

import "../node_modules/@kleros/erc-792/contracts/IArbitrable.sol";
import "../node_modules/@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "../node_modules/@kleros/erc-792/contracts/Arbitrator.sol";
import "./CrowdfundedAppeal.sol";

contract BinaryArbitrableProxy is IArbitrable, IEvidence {

    uint constant NUMBER_OF_CHOICES = 2;

    uint public sharedStakeMultiplier; // Multiplier for calculating the appeal fee that must be paid by submitter in the case where there isn't a winner and loser (e.g. when the arbitrator ruled "refuse to arbitrate").
    uint public winnerStakeMultiplier; // Multiplier for calculating the appeal fee of the party that won the previous round.
    uint public loserStakeMultiplier; // Multiplier for calculating the appeal fee of the party that lost the previous round.

    struct DisputeStruct {
        Arbitrator arbitrator;
        bytes arbitratorExtraData;
        bool isRuled;
        uint disputeIDOnArbitratorSide;
        CrowdfundedAppeal crowdfundingManager;
    }




    constructor(uint _sharedStakeMultipler, uint _winnerStakeMultiplier, uint _loserStakeMultiplier) public {
        sharedStakeMultiplier = _sharedStakeMultipler;
        winnerStakeMultiplier = _winnerStakeMultiplier;
        loserStakeMultiplier = _loserStakeMultiplier;
    }

    DisputeStruct[] public disputes;
    mapping(uint => DisputeStruct) public disputeIDOnArbitratorSidetoDisputeStruct;

    function createDispute(Arbitrator _arbitrator, bytes calldata _arbitratorExtraData, string calldata _metaevidenceURI) external payable {
        uint arbitrationCost = _arbitrator.arbitrationCost(_arbitratorExtraData);
        uint _disputeIDOnArbitratorSide = _arbitrator.createDispute.value(arbitrationCost)(NUMBER_OF_CHOICES, _arbitratorExtraData);

        uint disputeID = disputes.length++;
        DisputeStruct storage dispute = disputes[disputeID];
        dispute.arbitrator = _arbitrator;
        dispute.arbitratorExtraData = _arbitratorExtraData;
        dispute.disputeIDOnArbitratorSide = _disputeIDOnArbitratorSide;
        dispute.crowdfundingManager = new CrowdfundedAppeal(_arbitrator, _arbitratorExtraData, _disputeIDOnArbitratorSide, 2, sharedStakeMultiplier, winnerStakeMultiplier, loserStakeMultiplier);

        disputeIDOnArbitratorSidetoDisputeStruct[_disputeIDOnArbitratorSide] = disputes[disputes.length-1];

        emit MetaEvidence(disputes.length-1, _metaevidenceURI);

    }

    function appeal(uint _localDisputeID, uint _side) external {
        DisputeStruct storage dispute = disputes[_localDisputeID];

        (uint appealPeriodStart, uint appealPeriodEnd) = dispute.arbitrator.appealPeriod(dispute.disputeIDOnArbitratorSide);
        require(now >= appealPeriodStart && now < appealPeriodEnd, "Funding must be made within the appeal period.");

        dispute.crowdfundingManager.contribute(msg.sender, _side);
    }


    function rule(uint _localDisputeID, uint _ruling) external {
        DisputeStruct storage dispute = disputes[_localDisputeID];
        require(msg.sender == address(dispute.arbitrator), "Unauthorized call.");
        require(_ruling <= NUMBER_OF_CHOICES, "Invalid ruling.");
        require(dispute.isRuled == false, "Is ruled already.");

        emit Ruling(Arbitrator(msg.sender), dispute.disputeIDOnArbitratorSide, _ruling);
        dispute.isRuled = true;
    }

    function submitEvidence(uint _localDisputeID, string memory _evidenceURI) public {
        DisputeStruct storage dispute = disputes[_localDisputeID];

        require(dispute.isRuled == false, "Is ruled already.");

        emit Evidence(dispute.arbitrator, _localDisputeID, msg.sender, _evidenceURI);
    }
}
