pragma solidity >=0.5 <0.6.0;

import "../node_modules/@kleros/erc-792/contracts/IArbitrable.sol";
import "../node_modules/@kleros/erc-792/contracts/erc-1497/IEvidence.sol";
import "../node_modules/@kleros/erc-792/contracts/Arbitrator.sol";
import "../node_modules/@kleros/ethereum-libraries/contracts/CappedMath.sol";

contract CrowdfundedAppeal {

    using CappedMath for uint;

    IArbitrable public arbitrable = IArbitrable(msg.sender);
    Arbitrator public arbitrator;
    bytes public arbitratorExtraData;
    uint public disputeID;
    uint numberOfParties;

    uint constant NORMALIZATION_MULTIPLIER = 10000;
    uint public sharedStakeMultiplier; // Multiplier for calculating the appeal fee that must be paid by submitter in the case where there isn't a winner and loser (e.g. when the arbitrator ruled "refuse to arbitrate").
    uint public winnerStakeMultiplier; // Multiplier for calculating the appeal fee of the party that won the previous round.
    uint public loserStakeMultiplier; // Multiplier for calculating the appeal fee of the party that lost the previous round.

    struct Round {
        uint[] paidFees; // Tracks the fees paid by each side in this round.
        bool[] hasPaid; // True when the side has fully paid its fee. False otherwise.
        uint feeRewards; // Sum of reimbursable fees and stake rewards available to the parties that made contributions to the side that ultimately wins a dispute.
        mapping(address => uint[3]) contributions; // Maps contributors to their contributions for each side.
    }


    Round[]  rounds;

    constructor(Arbitrator _arbitrator, bytes memory _arbitratorExtraData, uint _disputeID, uint _numberOfParties, uint _sharedStakeMultipler, uint _winnerStakeMultiplier, uint _loserStakeMultiplier) public {
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
        disputeID = _disputeID;
        numberOfParties = _numberOfParties;

        rounds.length = 1;
        rounds[0].hasPaid.length = numberOfParties+1;
        rounds[0].paidFees.length = numberOfParties+1;

        sharedStakeMultiplier = _sharedStakeMultipler;
        winnerStakeMultiplier = _winnerStakeMultiplier;
        loserStakeMultiplier = _loserStakeMultiplier;
    }


    function contribute(address payable _contributor, uint _side) external payable {
        Round storage round = rounds[rounds.length-1];

        (uint appealPeriodStart, uint appealPeriodEnd) = arbitrator.appealPeriod(disputeID);
        require(now >= appealPeriodStart && now < appealPeriodEnd, "Funding must be made within the appeal period.");

        uint winner = arbitrator.currentRuling(disputeID);
        uint multiplier;
        if (winner == uint(_side)){
            multiplier = winnerStakeMultiplier;
        } else if (winner == 0){
            multiplier = sharedStakeMultiplier;
        } else {
            require(now - appealPeriodStart < (appealPeriodEnd - appealPeriodStart)/2, "The loser must pay during the first half of the appeal period.");
            multiplier = loserStakeMultiplier;
        }

        require(!round.hasPaid[uint(_side)], "Appeal fee has already been paid");

        uint appealCost = arbitrator.appealCost(disputeID, arbitratorExtraData);
        uint totalCost = appealCost.addCap((appealCost.mulCap(multiplier)) / NORMALIZATION_MULTIPLIER);

        uint contribution;


        if(round.paidFees[_side] + msg.value >= totalCost)
          contribution = totalCost - round.paidFees[_side];
        else
          contribution = msg.value;


          _contributor.send(msg.value - contribution);
          round.contributions[_contributor][_side] = contribution;
          round.paidFees[_side] += contribution;


        if(round.paidFees[_side]  + msg.value >= totalCost){
          arbitrator.appeal.value(appealCost)(disputeID, arbitratorExtraData);
          rounds.length++;
        }

    }


    function withdrawFeesAndRewards(address payable _contributor, uint _roundNumber) external {
      Round storage round = rounds[_roundNumber];
      uint currentRuling = arbitrator.currentRuling(disputeID);
      require(uint(arbitrator.disputeStatus(disputeID)) == uint(Arbitrator.DisputeStatus.Solved), "The dispute should be solved");
      uint reward;
      if (!round.hasPaid[1] || !round.hasPaid[2]) {
          // Allow to reimburse if funding was unsuccessful.
          reward = round.contributions[_contributor][1] + round.contributions[_contributor][2];
          round.contributions[_contributor][1] = 0;
          round.contributions[_contributor][2] = 0;
      } else if (currentRuling == 0) {
          // Reimburse unspent fees proportionally if there is no winner and loser.
          uint rewardTranslator = round.paidFees[1] > 0
              ? (round.contributions[_contributor][1] * round.feeRewards) / (round.paidFees[1] + round.paidFees[2])
              : 0;
          uint rewardChallenger = round.paidFees[2] > 0
              ? (round.contributions[_contributor][2] * round.feeRewards) / (round.paidFees[1] + round.paidFees[2])
              : 0;

          reward = rewardTranslator + rewardChallenger;
          round.contributions[_contributor][1] = 0;
          round.contributions[_contributor][2] = 0;
      } else {
            // Reward the winner.
            reward = round.paidFees[currentRuling] > 0
                ? (round.contributions[_contributor][currentRuling] * round.feeRewards) / round.paidFees[currentRuling]
                : 0;
            round.contributions[_contributor][currentRuling] = 0;
        }

      _contributor.send(reward); // It is the user responsibility to accept ETH.
  }


}
