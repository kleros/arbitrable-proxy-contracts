pragma solidity >=0.5 <0.6.0;

import "../node_modules/@kleros/erc-792/contracts/IArbitrable.sol";
import "../node_modules/@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "../node_modules/@kleros/erc-792/contracts/Arbitrator.sol";

contract BinaryArbitrableProxy is IArbitrable, IEvidence {

    uint constant NUMBER_OF_CHOICES = 2;

    struct DisputeStruct {
        Arbitrator arbitrator;
        bytes arbitratorExtraData;
        uint disputeID;
        bool isRuled;
        uint disputeIDOnArbitratorSide;
    }


    DisputeStruct[] disputes;
    mapping(uint => DisputeStruct) disputeIDOnArbitratorSidetoDisputeStruct;

    function createDispute(Arbitrator _arbitrator, bytes calldata _arbitratorExtraData, string calldata _metaevidenceURI) external payable {
        uint arbitrationCost = _arbitrator.arbitrationCost(_arbitratorExtraData);
        uint disputeIDOnArbitratorSide = _arbitrator.createDispute.value(arbitrationCost)(NUMBER_OF_CHOICES, _arbitratorExtraData);

        disputes.push(DisputeStruct({
            arbitrator: _arbitrator,
            arbitratorExtraData: _arbitratorExtraData,
            disputeID: disputeIDOnArbitratorSide,
            isRuled: false,
            disputeIDOnArbitratorSide: disputeIDOnArbitratorSide
        }));

        disputeIDOnArbitratorSidetoDisputeStruct[disputeIDOnArbitratorSide] = disputes[disputes.length];

        emit MetaEvidence(disputes.length-1, _metaevidenceURI);
    }

    function appeal(uint _localDisputeID) external payable {
        DisputeStruct storage dispute = disputes[_localDisputeID];
        dispute.arbitrator.appeal.value(msg.value)(dispute.disputeIDOnArbitratorSide, dispute.arbitratorExtraData);
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
