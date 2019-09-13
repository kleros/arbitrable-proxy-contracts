pragma solidity >=0.5 <0.6.0;

import "../node_modules/@kleros/erc-792/contracts/IArbitrable.sol";
import "../node_modules/@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "../node_modules/@kleros/erc-792/contracts/Arbitrator.sol";
import "./Crowdfunding.sol";

contract BinaryArbitrableProxy is IArbitrable, IEvidence {

    uint constant NUMBER_OF_CHOICES = 2;

    Crowdfunding crowdfunding;

    struct DisputeStruct {
        Arbitrator arbitrator;
        bytes arbitratorExtraData;
        bool isRuled;
        uint disputeIDOnArbitratorSide;
        Round[] rounds;
    }

    enum Party {
       None,
       Claimer,
       Challenger
   }
    struct Round {
      bool[3] hasPaid;
    }

    constructor(Crowdfunding _crowdfunding) public {
        crowdfunding = _crowdfunding;
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

        disputeIDOnArbitratorSidetoDisputeStruct[_disputeIDOnArbitratorSide] = disputes[disputes.length-1];

        emit MetaEvidence(disputes.length-1, _metaevidenceURI);

    }

    function appeal(uint _localDisputeID) external payable {
        DisputeStruct storage dispute = disputes[_localDisputeID];

        uint appealCost = dispute.arbitrator.appealCost(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);
        dispute.arbitrator.appeal.value(appealCost)(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);
    }

    function fundAppeal(uint _localDisputeID, uint _side)external {
        DisputeStruct storage dispute = disputes[_localDisputeID];
        uint round = dispute.rounds.length;

        uint appealCost = dispute.arbitrator.appealCost(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);
        crowdfunding.contribute(msg.sender, _localDisputeID, round, _side);
        if(crowdfunding.totalContributionOfADisputeForASideInARound(address(this),_localDisputeID,round,_side) >= appealCost)
        {
            uint excessContribution = crowdfunding.totalContributionOfADisputeForASideInARound(address(this),_localDisputeID,round,_side) - appealCost;
            msg.sender.send(excessContribution);
            crowdfunding.finalizeFunding(_localDisputeID, round, _side);
            dispute.rounds[round].hasPaid[_side] = true;
        }
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
