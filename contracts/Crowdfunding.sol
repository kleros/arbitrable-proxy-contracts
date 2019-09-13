pragma solidity >=0.5 <0.6.0;

import "../node_modules/@kleros/erc-792/contracts/IArbitrable.sol";
import "../node_modules/@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "../node_modules/@kleros/erc-792/contracts/Arbitrator.sol";

contract Crowdfunding {


    mapping(address => mapping(address => mapping(uint => mapping(uint => mapping(uint => uint))))) public contributor_arbitrable_dispute_round_side_to_value;
    mapping(address => mapping(uint => mapping(uint => mapping(uint => uint)))) public totalContributionOfADisputeForASideInARound;

    mapping(address => mapping(uint => mapping(uint => bool))) public arbitrable_round_side_is_refundable;

    function contribute(address payable _contributor, uint _disputeID, uint _round, uint _side) external payable {
        contributor_arbitrable_dispute_round_side_to_value[_contributor][msg.sender][_disputeID][_round][_side] = msg.value;
        totalContributionOfADisputeForASideInARound[msg.sender][_disputeID][_round][_side] += msg.value;
    }

    function setRefundable(uint _round, uint _side) external {
        arbitrable_round_side_is_refundable[msg.sender][_round][_side] = true;
    }

    function getRefund(address payable _contributor, uint _disputeID, uint _round, uint _side) external  {
        require(arbitrable_round_side_is_refundable[msg.sender][_round][_side], "This contribution is not refundable.");
        uint contribution = contributor_arbitrable_dispute_round_side_to_value[_contributor][msg.sender][_disputeID][_round][_side];
        contributor_arbitrable_dispute_round_side_to_value[_contributor][msg.sender][_disputeID][_round][_side] = 0;

        _contributor.transfer(contribution);
    }

    function finalizeFunding(uint _disputeID, uint _round, uint _side) external {
        uint totalContribution = totalContributionOfADisputeForASideInARound[msg.sender][_disputeID][_round][_side];
        totalContributionOfADisputeForASideInARound[msg.sender][_disputeID][_round][_side] = 0;
        msg.sender.transfer(totalContribution);
    }

}
