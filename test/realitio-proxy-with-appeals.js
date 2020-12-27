const { BN, expectRevert, time } = require("@openzeppelin/test-helpers");
const { soliditySha3 } = require("web3-utils");

const Arbitrator = artifacts.require("AutoAppealableArbitrator");
const Proxy = artifacts.require("RealitioArbitratorProxyWithAppeals");
const Realitio = artifacts.require("RealitioMock");

contract("RealitioArbitratorProxyWithAppeals", function (accounts) {
  const governor = accounts[0];
  const requester = accounts[1];
  const crowdfunder1 = accounts[2];
  const crowdfunder2 = accounts[3];
  const crowdfunder3 = accounts[4];
  const answerer = accounts[5];
  const other = accounts[9];
  const arbitratorExtraData = "0x85";
  const arbitrationCost = 1000;
  const appealCost = 5000;

  const appealTimeOut = 180;
  const winnerMultiplier = 3000;
  const loserMultiplier = 7000;

  const questionHashed = soliditySha3("question");
  const questionID =
    "37982889683569963184062620292954163810666454706822743503198502129467053274669"; // Question's hash in uint.
  const gasPrice = 8000000;
  const MAX_ANSWER =
    "115792089237316195423570985008687907853269984665640564039457584007913129639935";

  let arbitrator;
  let realitio;
  let proxy;

  beforeEach("initialize the contract", async function () {
    arbitrator = await Arbitrator.new(arbitrationCost, { from: governor });

    await arbitrator.createDispute(42, arbitratorExtraData, {
      from: other,
      value: arbitrationCost,
    });
    await arbitrator.createDispute(4, arbitratorExtraData, {
      from: other,
      value: arbitrationCost,
    }); // Create disputes so the index in tests will not be a default value.

    realitio = await Realitio.new({ from: governor });

    proxy = await Proxy.new(
      arbitrator.address,
      arbitratorExtraData,
      realitio.address,
      winnerMultiplier,
      loserMultiplier,
      { from: governor }
    );
    await realitio.setArbitratorAndQuestion(proxy.address, questionHashed, {
      from: governor,
    });
  });

  it("Should set correct values in constructor", async () => {
    assert.equal(
      await proxy.arbitrator(),
      arbitrator.address,
      "Incorrect arbitrator address"
    );
    assert.equal(
      await proxy.arbitratorExtraData(),
      "0x85",
      "Incorrect extradata"
    );
    assert.equal(
      await proxy.deployer(),
      governor,
      "Incorrect deployer address"
    );
    assert.equal(
      await proxy.governor(),
      governor,
      "Incorrect governor address"
    );
    assert.equal(
      await proxy.realitio(),
      realitio.address,
      "Incorrect Realitio address"
    );

    // 0 - winner, 1 - loser, 2 - shared, 3 - divisor.
    const multipliers = await proxy.getMultipliers();
    assert.equal(
      multipliers[0].toNumber(),
      3000,
      "Incorrect winner multiplier"
    );
    assert.equal(multipliers[1].toNumber(), 7000, "Incorrect loser multiplier");
    assert.equal(multipliers[2].toNumber(), 0, "Incorrect shared multiplier");
    assert.equal(
      multipliers[3].toNumber(),
      10000,
      "Incorrect multiplier divisor"
    );
  });

  it("Should set correct values when requesting arbitration and fire the event", async () => {
    // Check that can't pay less.
    await expectRevert(
      proxy.requestArbitration(questionHashed, 0, {
        from: requester,
        value: arbitrationCost - 1,
      }),
      "Value is less than required arbitration fee."
    );
    const txRequest = await proxy.requestArbitration(questionHashed, 0, {
      from: requester,
      value: arbitrationCost,
    });

    const questionData = await proxy.questions(questionID);
    assert.equal(questionData[0], requester, "Incorrect requester address");
    assert.equal(questionData[1].toNumber(), 1, "Incorrect status");
    assert.equal(questionData[2].toNumber(), 2, "Incorrect dispute ID");
    assert.equal(questionData[3].toNumber(), 0, "Answer should not be set");
    assert.equal(
      (await proxy.getNumberOfRounds(questionID)).toNumber(),
      1,
      "Incorrect number of rounds"
    );

    const nbRulings = (
      await proxy.numberOfRulingOptions(questionID)
    ).toString();

    const dispute = await arbitrator.disputes(2);
    assert.equal(dispute[0], proxy.address, "Arbitrable not set up properly");
    assert.equal(
      dispute[1].toString(),
      nbRulings,
      "Number of choices not set up properly"
    );
    assert.equal(
      dispute[2].toNumber(),
      arbitrationCost,
      "Arbitration fee not set up properly"
    );
    assert.equal(
      await proxy.externalIDtoLocalID(2),
      questionID,
      "Incorrect externalIDtoLocalID value"
    );
    assert.equal(
      await realitio.is_pending_arbitration(),
      true,
      "Arbitration flag is not set in Realitio"
    );

    // Events.
    assert.equal(
      txRequest.logs[0].event,
      "Dispute",
      "Event Dispute has not been created"
    );
    assert.equal(
      txRequest.logs[0].args._arbitrator,
      arbitrator.address,
      "Event Dispute has wrong arbitrator address"
    );
    assert.equal(
      txRequest.logs[0].args._disputeID.toNumber(),
      2,
      "Event Dispute has wrong dispute ID"
    );
    assert.equal(
      txRequest.logs[0].args._metaEvidenceID.toNumber(),
      0,
      "Event Dispute has wrong metaevidence ID"
    );
    assert.equal(
      parseInt(txRequest.logs[0].args._evidenceGroupID, 10),
      questionID,
      "Event Dispute has wrong evidence group ID"
    );

    // Check that can't make a request the 2nd time.
    await expectRevert(
      proxy.requestArbitration(questionHashed, 0, {
        from: requester,
        value: arbitrationCost,
      }),
      "The arbitration has already been requested for this question."
    );
  });

  it("Should correctly fund an appeal and fire the events", async () => {
    let oldBalance;
    let newBalance;
    let roundInfo;
    let fundingStatus;
    let txFundAppeal;
    let txFee;
    await expectRevert(
      proxy.fundAppeal(questionID, 75, {
        from: crowdfunder1,
        value: arbitrationCost,
      }),
      "No dispute to appeal."
    );

    await proxy.requestArbitration(questionHashed, 0, {
      from: requester,
      value: arbitrationCost,
    });

    await expectRevert(
      proxy.fundAppeal(1, 75, { from: crowdfunder1, value: arbitrationCost }),
      "No dispute to appeal."
    );

    // Check that can't fund the dispute that is not appealable.
    await expectRevert(
      proxy.fundAppeal(questionID, 75, {
        from: crowdfunder1,
        value: arbitrationCost,
      }),
      "Appeal fees must be paid within the appeal period."
    );

    await arbitrator.giveAppealableRuling(2, 51231, appealCost, appealTimeOut, {
      from: governor,
    });

    const nbRulings = await proxy.numberOfRulingOptions(questionID); // The answer ID that is equal to the number of ruling can't be funded.

    // loserFee = appealCost + (appealCost * loserMultiplier / 10000) // 5000 + 5000 * 7/10 = 8500
    // 1st Funding ////////////////////////////////////
    oldBalance = await web3.eth.getBalance(crowdfunder1);
    txFundAppeal = await proxy.fundAppeal(questionID, 533, {
      from: crowdfunder1,
      gasPrice: gasPrice,
      value: appealCost,
    }); // This value doesn't fund fully.
    txFee = txFundAppeal.receipt.gasUsed * gasPrice;

    newBalance = await web3.eth.getBalance(crowdfunder1);
    assert(
      new BN(newBalance).eq(
        new BN(oldBalance).sub(new BN(5000).add(new BN(txFee)))
      ),
      "The crowdfunder has incorrect balance after the first funding"
    );

    roundInfo = await proxy.getRoundInfo(questionID, 0);
    assert.equal(
      roundInfo[1].toNumber(),
      0,
      "feeRewards value should be 0 after partial funding"
    );
    fundingStatus = await proxy.getFundingStatus(questionID, 0, 533);
    assert.equal(
      fundingStatus[0].toNumber(),
      5000,
      "Incorrect amount of paidFees registered after the first funding"
    );
    assert.equal(
      fundingStatus[1],
      false,
      "The answer should not be fully funded after partial funding"
    );

    // Events, 1st funding.
    assert.equal(
      txFundAppeal.logs[0].event,
      "Contribution",
      "Event Contribution has not been created"
    );
    assert.equal(
      parseInt(txFundAppeal.logs[0].args.localDisputeID, 10),
      questionID,
      "Event Contribution has wrong dispute ID"
    );
    assert.equal(
      txFundAppeal.logs[0].args.round.toNumber(),
      0,
      "Event Contribution has wrong round ID"
    );
    assert.equal(
      txFundAppeal.logs[0].args.ruling.toNumber(),
      534, // Ruling is equal to asnwer + 1
      "Event Contribution has incorrect ruling"
    );
    assert.equal(
      txFundAppeal.logs[0].args.contributor,
      crowdfunder1,
      "Event Contribution has incorrect contributor"
    );
    assert.equal(
      txFundAppeal.logs[0].args.amount.toNumber(),
      5000,
      "Event Contribution has incorrect amount"
    );

    // 2nd Funding ////////////////////////////////////
    oldBalance = newBalance;
    txFundAppeal = await proxy.fundAppeal(questionID, 533, {
      from: crowdfunder1,
      gasPrice: gasPrice,
      value: 1e18,
    }); // Overpay to check that it's handled correctly.
    txFee = txFundAppeal.receipt.gasUsed * gasPrice;
    newBalance = await web3.eth.getBalance(crowdfunder1);
    assert(
      new BN(newBalance).eq(
        new BN(oldBalance).sub(new BN(3500).add(new BN(txFee)))
      ),
      "The crowdfunder has incorrect balance after the second funding"
    );

    roundInfo = await proxy.getRoundInfo(questionID, 0);
    assert.equal(
      roundInfo[0][0].toNumber(),
      8500,
      "Incorrect paidFees value of the fully funded answer"
    );
    assert.equal(
      roundInfo[1].toNumber(),
      8500,
      "Incorrect feeRewards value after the full funding"
    );
    assert.equal(
      roundInfo[2][0].toNumber(),
      533,
      "Incorrect funded answer stored"
    );

    fundingStatus = await proxy.getFundingStatus(questionID, 0, 533);
    assert.equal(
      fundingStatus[0].toNumber(),
      8500,
      "Incorrect amount of paidFees registered after the second funding"
    );
    assert.equal(
      fundingStatus[1],
      true,
      "The answer should be fully funded after the second funding"
    );

    const contributionInfo = await proxy.getContributionsToSuccessfulFundings(
      questionID,
      0,
      crowdfunder1
    );
    assert.equal(
      contributionInfo[0][0].toNumber(),
      533,
      "Incorrect fully funded answer returned by contrbution info"
    );
    assert.equal(
      contributionInfo[1][0].toNumber(),
      8500,
      "Incorrect contribution value returned by contrbution info"
    );

    assert.equal(
      (await proxy.getNumberOfRounds(questionID)).toNumber(),
      1,
      "Number of rounds should not increase"
    );

    // Events, 2nd funding.
    assert.equal(
      txFundAppeal.logs[0].event,
      "Contribution",
      "Event Contribution has not been created after 2nd funding"
    );
    assert.equal(
      parseInt(txFundAppeal.logs[0].args.localDisputeID, 10),
      questionID,
      "Event Contribution has wrong dispute ID after 2nd funding"
    );
    assert.equal(
      txFundAppeal.logs[0].args.round.toNumber(),
      0,
      "Event Contribution has wrong round ID after 2nd funding"
    );
    assert.equal(
      txFundAppeal.logs[0].args.ruling.toNumber(),
      534, // Ruling is equal to asnwer + 1
      "Event Contribution has incorrect ruling after 2nd funding"
    );
    assert.equal(
      txFundAppeal.logs[0].args.contributor,
      crowdfunder1,
      "Event Contribution has incorrect contributor after 2nd funding"
    );
    assert.equal(
      txFundAppeal.logs[0].args.amount.toNumber(),
      3500,
      "Event Contribution has incorrect amount after 2nd funding"
    );

    assert.equal(
      txFundAppeal.logs[1].event,
      "RulingFunded",
      "Event RulingFunded has not been created"
    );
    assert.equal(
      parseInt(txFundAppeal.logs[1].args.localDisputeID, 10),
      questionID,
      "Event RulingFunded has wrong dispute ID"
    );
    assert.equal(
      txFundAppeal.logs[0].args.round.toNumber(),
      0,
      "Event RulingFunded has wrong round ID"
    );
    assert.equal(
      txFundAppeal.logs[0].args.ruling.toNumber(),
      534, // Ruling is equal to asnwer + 1
      "Event RulingFunded has incorrect ruling"
    );

    await expectRevert(
      proxy.fundAppeal(questionID, 533, { from: crowdfunder1, value: 1e18 }),
      "Appeal fee has already been paid."
    );
  });

  it("Should correctly create and fund subsequent appeal rounds", async () => {
    let roundInfo;
    await proxy.requestArbitration(questionHashed, 0, {
      from: requester,
      value: arbitrationCost,
    });
    await arbitrator.giveAppealableRuling(2, 21, appealCost, appealTimeOut, {
      from: governor,
    });

    await proxy.fundAppeal(questionID, 14, { from: crowdfunder1, value: 8500 });
    await proxy.fundAppeal(questionID, 20, { from: crowdfunder2, value: 5000 }); // Winner appeal fee is 6500 full.

    assert.equal(
      (await proxy.getNumberOfRounds(questionID)).toNumber(),
      1,
      "Number of rounds should not increase"
    );

    await proxy.fundAppeal(questionID, 20, { from: crowdfunder3, value: 1500 });

    assert.equal(
      (await proxy.getNumberOfRounds(questionID)).toNumber(),
      2,
      "Number of rounds should increase after two sides are fully funded"
    );

    roundInfo = await proxy.getRoundInfo(questionID, 0);
    assert.equal(
      roundInfo[1].toNumber(),
      10000, // 8500 + 6500 - 5000.
      "Incorrect feeRewards value after creating a 2nd round"
    );

    await arbitrator.giveAppealableRuling(2, 0, appealCost, appealTimeOut, {
      from: governor,
    });
    // Fund 0 answer to make sure it's not treated as 0 ruling because of -1 offset.
    await proxy.fundAppeal(questionID, 0, { from: crowdfunder1, value: 1e18 });

    roundInfo = await proxy.getRoundInfo(questionID, 1);
    assert.equal(
      roundInfo[0][0].toNumber(),
      8500, // total loser fee = 5000 + 5000 * 0.7
      "Incorrect paidFees value after funding 0 answer"
    );
    assert.equal(
      roundInfo[2][0].toNumber(),
      0,
      "0 answer was not stored correctly"
    );

    // Max number is the equivalent of 0 ruling and should be considered a winner.
    await proxy.fundAppeal(questionID, MAX_ANSWER, {
      from: crowdfunder1,
      value: 6500,
    });
    roundInfo = await proxy.getRoundInfo(questionID, 1);
    assert.equal(
      roundInfo[0][1].toNumber(),
      6500,
      "Incorrect paidFees value for 2nd crowdfunder"
    );
    assert.equal(
      roundInfo[1].toNumber(),
      10000, // 8500 + 6500 - 5000.
      "Incorrect feeRewards value after creating a 3rd round"
    );
    assert.equal(
      roundInfo[2][1].toString(),
      MAX_ANSWER,
      "-1 answer was not stored correctly"
    );

    assert.equal(
      (await proxy.getNumberOfRounds(questionID)).toNumber(),
      3,
      "Number of rounds should increase to 3"
    );

    // Check that newly created round is empty.
    roundInfo = await proxy.getRoundInfo(questionID, 2);
    assert.equal(
      roundInfo[1].toNumber(),
      0,
      "Incorrect feeRewards value in fresh round"
    );
  });

  it("Should not fund the appeal after the timeout", async () => {
    await proxy.requestArbitration(questionHashed, 0, {
      from: requester,
      value: arbitrationCost,
    });
    await arbitrator.giveAppealableRuling(2, 441, appealCost, appealTimeOut, {
      from: governor,
    });

    await time.increase(appealTimeOut / 2 + 1);

    // Loser.
    await expectRevert(
      proxy.fundAppeal(questionID, 5, { from: crowdfunder1, value: 1e18 }),
      "The loser must pay during the first half of the appeal period."
    );

    // Adding another half will cover the whole period.
    await time.increase(appealTimeOut / 2 + 1);

    // Winner.
    await expectRevert(
      proxy.fundAppeal(questionID, 440, { from: crowdfunder2, value: 1e18 }),
      "Appeal fees must be paid within the appeal period."
    );
  });

  it("Should correctly withdraw appeal fees if a dispute had winner/loser", async () => {
    let oldBalance1;
    let oldBalance2;
    let newBalance;
    let newBalance1;
    let newBalance2;

    await proxy.requestArbitration(questionHashed, 0, {
      from: requester,
      value: arbitrationCost,
    });
    await arbitrator.giveAppealableRuling(2, 5, appealCost, appealTimeOut, {
      from: governor,
    });

    // LoserFee = 8500, WinnerFee = 6500. AppealCost = 5000.
    // 0 Round.
    await proxy.fundAppeal(questionID, 50, { from: requester, value: 4000 });
    await proxy.fundAppeal(questionID, 50, { from: crowdfunder1, value: 1e18 });

    await proxy.fundAppeal(questionID, 4, { from: crowdfunder2, value: 6000 });
    await proxy.fundAppeal(questionID, 4, { from: crowdfunder1, value: 500 });

    await arbitrator.giveAppealableRuling(2, 5, appealCost, appealTimeOut, {
      from: governor,
    });

    // 1 Round.
    await proxy.fundAppeal(questionID, 44, { from: requester, value: 500 });
    await proxy.fundAppeal(questionID, 44, { from: crowdfunder1, value: 8000 });

    await proxy.fundAppeal(questionID, 4, { from: crowdfunder2, value: 20000 });

    await arbitrator.giveAppealableRuling(2, 5, appealCost, appealTimeOut, {
      from: governor,
    });

    // 2 Round.
    // Partially funded side should be reimbursed.
    await proxy.fundAppeal(questionID, 41, { from: requester, value: 8499 });
    // Winner doesn't have to fund appeal in this case but let's check if it causes unexpected behaviour.
    await proxy.fundAppeal(questionID, 4, { from: crowdfunder2, value: 1e18 });

    await time.increase(appealTimeOut + 1);

    await expectRevert(
      proxy.withdrawFeesAndRewards(questionID, requester, 0, 50, {
        from: governor,
      }),
      "Dispute not resolved."
    );

    await arbitrator.executeRuling(2, { from: governor });

    let ruling = (await arbitrator.currentRuling(2)).toNumber() - 1;

    const questionData = await proxy.questions(questionID);
    assert.equal(questionData[1].toNumber(), 2, "Status should be ruled");
    // Stored answer has a type bytes32 but it can still be compared to uint.
    assert.equal(
      questionData[3].toNumber(),
      ruling,
      "Stored answer is incorrect"
    );

    const oldBalance = await web3.eth.getBalance(requester);
    oldBalance1 = await web3.eth.getBalance(crowdfunder1);
    oldBalance2 = await web3.eth.getBalance(crowdfunder2);

    // Withdraw 0 round.
    await proxy.withdrawFeesAndRewards(questionID, requester, 0, 50, {
      from: governor,
    });
    newBalance = await web3.eth.getBalance(requester);
    assert(
      new BN(newBalance).eq(new BN(oldBalance)),
      "The balance of the requester should stay the same (withdraw 0 round)"
    );
    await proxy.withdrawFeesAndRewards(questionID, requester, 0, 4, {
      from: governor,
    });
    newBalance = await web3.eth.getBalance(requester);
    assert(
      new BN(newBalance).eq(new BN(oldBalance)),
      "The balance of the requester should stay the same (withdraw 0 round from winning ruling)"
    );

    await proxy.withdrawFeesAndRewards(questionID, crowdfunder1, 0, 50, {
      from: governor,
    });
    newBalance1 = await web3.eth.getBalance(crowdfunder1);
    assert(
      new BN(newBalance1).eq(new BN(oldBalance1)),
      "The balance of the crowdfunder1 should stay the same (withdraw 0 round)"
    );
    const txWithdraw = await proxy.withdrawFeesAndRewards(
      questionID,
      crowdfunder1,
      0,
      4,
      { from: governor }
    );
    newBalance1 = await web3.eth.getBalance(crowdfunder1);
    assert(
      new BN(newBalance1).eq(
        new BN(oldBalance1).add(new BN(769)) // 500 / 6500 * 10000.
      ),
      "The balance of the crowdfunder1 is incorrect after withdrawing from winning ruling 0 round"
    );
    oldBalance1 = newBalance1;

    assert.equal(
      txWithdraw.logs[0].event,
      "Withdrawal",
      "Event Withdrawal has not been created"
    );
    assert.equal(
      parseInt(txWithdraw.logs[0].args.localDisputeID, 10),
      questionID,
      "Event Withdrawal has wrong dispute ID"
    );
    assert.equal(
      txWithdraw.logs[0].args.round.toNumber(),
      0,
      "Event Withdrawal has wrong round ID"
    );
    assert.equal(
      txWithdraw.logs[0].args.ruling.toNumber(),
      5, // Ruling is equal to asnwer + 1
      "Event Withdrawal has incorrect ruling"
    );
    assert.equal(
      txWithdraw.logs[0].args.contributor,
      crowdfunder1,
      "Event Withdrawal has incorrect contributor"
    );
    assert.equal(
      txWithdraw.logs[0].args.reward.toNumber(),
      769,
      "Event Withdrawal has incorrect reward value"
    );

    await proxy.withdrawFeesAndRewards(questionID, crowdfunder1, 0, 4, {
      from: governor,
    });
    newBalance1 = await web3.eth.getBalance(crowdfunder1);
    assert(
      new BN(newBalance1).eq(new BN(oldBalance1)),
      "The balance of the crowdfunder1 should stay the same after withdrawing the 2nd time"
    );

    await proxy.withdrawFeesAndRewards(questionID, crowdfunder2, 0, 4, {
      from: governor,
    });
    newBalance2 = await web3.eth.getBalance(crowdfunder2);
    assert(
      new BN(newBalance2).eq(
        new BN(oldBalance2).add(new BN(9230)) // 12 / 13 * 10000
      ),
      "The balance of the crowdfunder2 is incorrect (withdraw 0 round)"
    );
    oldBalance2 = newBalance2;

    let contributionInfo = await proxy.getContributionsToSuccessfulFundings(
      questionID,
      0,
      crowdfunder1
    );
    assert.equal(
      contributionInfo[1][1].toNumber(),
      0,
      "Contribution of crowdfunder1 should be 0"
    );
    contributionInfo = await proxy.getContributionsToSuccessfulFundings(
      questionID,
      0,
      crowdfunder2
    );
    assert.equal(
      contributionInfo[1][0].toNumber(),
      0,
      "Contribution of crowdfunder2 should be 0"
    );

    // Withdraw 1 round.
    await proxy.withdrawFeesAndRewards(questionID, requester, 1, 4, {
      from: governor,
    });
    await proxy.withdrawFeesAndRewards(questionID, requester, 1, 44, {
      from: governor,
    });
    await proxy.withdrawFeesAndRewards(questionID, crowdfunder1, 1, 4, {
      from: governor,
    });
    await proxy.withdrawFeesAndRewards(questionID, crowdfunder1, 1, 44, {
      from: governor,
    });
    await proxy.withdrawFeesAndRewards(questionID, crowdfunder2, 1, 4, {
      from: governor,
    });
    newBalance = await web3.eth.getBalance(requester);
    newBalance1 = await web3.eth.getBalance(crowdfunder1);
    newBalance2 = await web3.eth.getBalance(crowdfunder2);
    assert(
      new BN(newBalance).eq(new BN(oldBalance)),
      "The balance of the requester should stay the same (withdraw 1 round)"
    );
    assert(
      new BN(newBalance1).eq(new BN(oldBalance1)),
      "The balance of the crowdfunder1 should stay the same (withdraw 1 round)"
    );
    assert(
      new BN(newBalance2).eq(
        new BN(oldBalance2).add(new BN(10000)) // Full reward.
      ),
      "The balance of the crowdfunder2 is incorrect (withdraw 1 round)"
    );
    contributionInfo = await proxy.getContributionsToSuccessfulFundings(
      questionID,
      1,
      crowdfunder2
    );
    assert.equal(
      contributionInfo[1][0].toNumber(),
      0,
      "Contribution of crowdfunder2 should be 0 in 1 round"
    );
    oldBalance2 = newBalance2;

    // Withdraw 2 round.
    await proxy.withdrawFeesAndRewards(questionID, requester, 2, 41, {
      from: governor,
    });
    await proxy.withdrawFeesAndRewards(questionID, crowdfunder2, 2, 4, {
      from: governor,
    });
    newBalance = await web3.eth.getBalance(requester);
    newBalance2 = await web3.eth.getBalance(crowdfunder2);
    assert(
      new BN(newBalance).eq(new BN(oldBalance).add(new BN(8499))),
      "The balance of the requester is incorrect (withdraw 2 round)"
    );
    assert(
      new BN(newBalance2).eq(
        new BN(oldBalance2).add(new BN(6500)) // Full winner fee is reimbursed.
      ),
      "The balance of the crowdfunder2 is incorrect (withdraw 2 round)"
    );
    contributionInfo = await proxy.getContributionsToSuccessfulFundings(
      questionID,
      2,
      crowdfunder2
    );
    assert.equal(
      contributionInfo[1][0].toNumber(),
      0,
      "Contribution of crowdfunder2 should be 0 in 2 round"
    );
  });

  it("Should correctly withdraw appeal fees if the winner did not pay the fees in the round", async () => {
    let oldBalance;
    let newBalance;

    await proxy.requestArbitration(questionHashed, 0, {
      from: requester,
      value: arbitrationCost,
    });
    await arbitrator.giveAppealableRuling(2, 20, appealCost, appealTimeOut, {
      from: governor,
    });

    // LoserFee = 8500. AppealCost = 5000.
    await proxy.fundAppeal(questionID, 1, { from: requester, value: 5000 });
    await proxy.fundAppeal(questionID, 1, { from: crowdfunder1, value: 3500 });

    await proxy.fundAppeal(questionID, 4, { from: crowdfunder2, value: 1000 });
    await proxy.fundAppeal(questionID, 4, { from: crowdfunder1, value: 10000 });

    await arbitrator.giveAppealableRuling(2, 20, appealCost, appealTimeOut, {
      from: governor,
    });
    await time.increase(appealTimeOut + 1);

    await arbitrator.executeRuling(2, { from: governor });

    oldBalance = await web3.eth.getBalance(requester);
    await proxy.withdrawFeesAndRewards(questionID, requester, 0, 1, {
      from: governor,
    });
    newBalance = await web3.eth.getBalance(requester);
    assert(
      new BN(newBalance).eq(
        new BN(oldBalance).add(new BN(3529)) // 5000 * 12000 / 17000.
      ),
      "The balance of the requester is incorrect"
    );

    oldBalance = await web3.eth.getBalance(crowdfunder1);
    await proxy.withdrawFeesAndRewards(questionID, crowdfunder1, 0, 1, {
      from: governor,
    });
    newBalance = await web3.eth.getBalance(crowdfunder1);
    assert(
      new BN(newBalance).eq(
        new BN(oldBalance).add(new BN(2470)) // 3500 * 12000 / 17000.
      ),
      "The balance of the crowdfunder1 is incorrect (1 ruling)"
    );
    oldBalance = newBalance;

    await proxy.withdrawFeesAndRewards(questionID, crowdfunder1, 0, 4, {
      from: governor,
    });
    newBalance = await web3.eth.getBalance(crowdfunder1);
    assert(
      new BN(newBalance).eq(
        new BN(oldBalance).add(new BN(5294)) // 7500 * 12000 / 17000.
      ),
      "The balance of the crowdfunder1 is incorrect (4 ruling)"
    );

    oldBalance = await web3.eth.getBalance(crowdfunder2);
    await proxy.withdrawFeesAndRewards(questionID, crowdfunder2, 0, 4, {
      from: governor,
    });
    newBalance = await web3.eth.getBalance(crowdfunder2);
    assert(
      new BN(newBalance).eq(
        new BN(oldBalance).add(new BN(705)) // 1000 * 12000 / 17000.
      ),
      "The balance of the crowdfunder2 is incorrect"
    );
  });

  it("Should correctly withdraw appeal fees for multiple answers", async () => {
    let oldBalance;
    let newBalance;

    await proxy.requestArbitration(questionHashed, 0, {
      from: requester,
      value: arbitrationCost,
    });
    await arbitrator.giveAppealableRuling(2, 17, appealCost, appealTimeOut, {
      from: governor,
    });

    // LoserFee = 8500. AppealCost = 5000.
    await proxy.fundAppeal(questionID, 1, { from: requester, value: 5000 });
    await proxy.fundAppeal(questionID, 1, { from: crowdfunder1, value: 3500 });

    // Not fully funded answers.
    await proxy.fundAppeal(questionID, 41, { from: requester, value: 17 });
    await proxy.fundAppeal(questionID, 45, { from: requester, value: 22 });
    //

    await proxy.fundAppeal(questionID, 2, { from: requester, value: 1000 });
    await proxy.fundAppeal(questionID, 2, { from: crowdfunder1, value: 10000 });

    // Final answer was not funded.
    await arbitrator.giveAppealableRuling(2, 17, appealCost, appealTimeOut, {
      from: governor,
    });
    await time.increase(appealTimeOut + 1);

    await arbitrator.executeRuling(2, { from: governor });

    oldBalance = await web3.eth.getBalance(requester);
    await proxy.withdrawFeesAndRewardsForMultipleRulings(
      questionID,
      requester,
      0,
      [1, 2],
      { from: governor }
    );
    newBalance = await web3.eth.getBalance(requester);
    assert(
      new BN(newBalance).eq(
        new BN(oldBalance).add(new BN(4234)) // 5000 * 12000 / 17000 + 1000 * 12000 / 17000 = 3529 + 705
      ),
      "The balance of the requester is incorrect"
    );

    oldBalance = await web3.eth.getBalance(requester);
    await proxy.withdrawFeesAndRewardsForMultipleRulings(
      questionID,
      requester,
      0,
      [41, 45],
      { from: governor }
    );
    newBalance = await web3.eth.getBalance(requester);
    assert(
      new BN(newBalance).eq(new BN(oldBalance).add(new BN(39))),
      "The balance of the requester is incorrect after withdrawing not fully funded answers"
    );

    oldBalance = await web3.eth.getBalance(crowdfunder1);
    await proxy.withdrawFeesAndRewardsForMultipleRulings(
      questionID,
      crowdfunder1,
      0,
      [1, 2],
      { from: governor }
    );
    newBalance = await web3.eth.getBalance(crowdfunder1);
    assert(
      new BN(newBalance).eq(
        new BN(oldBalance).add(new BN(7764)) // 3500 * 12000 / 17000 + 7500 * 12000 / 17000 = 2470 + 5294
      ),
      "The balance of the crowdfunder1 is incorrect"
    );

    oldBalance = await web3.eth.getBalance(crowdfunder1);
    await proxy.withdrawFeesAndRewardsForMultipleRulings(
      questionID,
      crowdfunder1,
      0,
      [1, 2],
      { from: governor }
    );
    newBalance = await web3.eth.getBalance(crowdfunder1);
    assert(
      new BN(newBalance).eq(new BN(oldBalance)),
      "The balance of the crowdfunder1 should stay the same after withdrawing the 2nd time"
    );
  });

  it("Should correctly withdraw appeal fees for multiple rounds", async () => {
    let oldBalance;
    let newBalance;

    await proxy.requestArbitration(questionHashed, 0, {
      from: requester,
      value: arbitrationCost,
    });
    await arbitrator.giveAppealableRuling(2, 3, appealCost, appealTimeOut, {
      from: governor,
    });

    // LoserFee = 8500. AppealCost = 5000.
    // WinnerFee = 6500.
    await proxy.fundAppeal(questionID, 1, { from: requester, value: 5000 });
    await proxy.fundAppeal(questionID, 1, { from: crowdfunder1, value: 3500 });

    await proxy.fundAppeal(questionID, 2, { from: requester, value: 1000 });
    await proxy.fundAppeal(questionID, 2, { from: crowdfunder1, value: 10000 });

    // 2 answer is the winner.
    await arbitrator.giveAppealableRuling(2, 3, appealCost, appealTimeOut, {
      from: governor,
    });

    await proxy.fundAppeal(questionID, 41, { from: requester, value: 17 });
    await proxy.fundAppeal(questionID, 45, { from: crowdfunder1, value: 22 });

    await time.increase(appealTimeOut + 1);

    await arbitrator.executeRuling(2, { from: governor });

    oldBalance = await web3.eth.getBalance(requester);
    await proxy.withdrawFeesAndRewardsForAllRounds(
      questionID,
      requester,
      [1, 2, 41],
      {
        from: governor,
      }
    );
    newBalance = await web3.eth.getBalance(requester);
    assert(
      new BN(newBalance).eq(
        new BN(oldBalance).add(new BN(1555)) // 1000 * 10000 / 6500 + 17 = 1538 + 17
      ),
      "The balance of the requester is incorrect"
    );

    oldBalance = await web3.eth.getBalance(crowdfunder1);
    await proxy.withdrawFeesAndRewardsForAllRounds(
      questionID,
      crowdfunder1,
      [1, 2, 45],
      { from: governor }
    );
    newBalance = await web3.eth.getBalance(crowdfunder1);
    assert(
      new BN(newBalance).eq(
        new BN(oldBalance).add(new BN(8483)) // 5500 * 10000 / 6500 + 22 = 8461 + 22
      ),
      "The balance of the crowdfunder1 is incorrect"
    );
  });

  it("Should store correct ruling when dispute had winner/loser", async () => {
    await proxy.requestArbitration(questionHashed, 0, {
      from: requester,
      value: arbitrationCost,
    });
    await expectRevert(
      proxy.rule(2, 15, { from: requester }),
      "Must be called by the arbitrator."
    );

    await arbitrator.giveRuling(2, 15, { from: governor });
    const questionData = await proxy.questions(questionID);
    assert.equal(questionData[1].toNumber(), 2, "The status should be Ruled");
    assert.equal(questionData[3], 14, "Stored answer is incorrect");
  });

  it("Should store 0 ruling correctly", async () => {
    await proxy.requestArbitration(questionHashed, 0, {
      from: requester,
      value: arbitrationCost,
    });

    await arbitrator.giveRuling(2, 0, { from: governor });
    const questionData = await proxy.questions(questionID);
    assert.equal(questionData[1].toNumber(), 2, "The status should be Ruled");
    assert.equal(
      questionData[3].toString(),
      MAX_ANSWER,
      "The answer should be MAX"
    );
  });

  it("Should switch the ruling if the loser paid appeal fees while winner did not", async () => {
    await proxy.requestArbitration(questionHashed, 0, {
      from: requester,
      value: arbitrationCost,
    });

    await arbitrator.giveAppealableRuling(2, 14, appealCost, appealTimeOut, {
      from: governor,
    });

    await proxy.fundAppeal(questionID, 50, { from: crowdfunder1, value: 1e18 });
    await time.increase(appealTimeOut + 1);
    await arbitrator.executeRuling(2, { from: governor });

    const questionData = await proxy.questions(questionID);
    assert.equal(questionData[1].toNumber(), 2, "The status should be Ruled");
    assert.equal(questionData[3], 50, "The answer should be 50");
  });

  it("Should set correct values when answer is reported to Realitio", async () => {
    await proxy.requestArbitration(questionHashed, 0, {
      from: requester,
      value: arbitrationCost,
    });

    const realitioAnswer = await realitio.toBytes(22);
    const badAnswer = await realitio.toBytes(23);
    const lastHistoryHash = await realitio.getHistoryHash(questionHashed);
    await realitio.addAnswerToHistory(realitioAnswer, answerer, 2000, false);

    const currentHash = soliditySha3(
      lastHistoryHash,
      realitioAnswer,
      2000,
      answerer,
      false
    );
    assert.equal(
      await realitio.getHistoryHash(questionHashed),
      currentHash,
      "Realitio hash is incorrect"
    );

    await expectRevert(
      proxy.reportAnswer(
        questionID,
        lastHistoryHash,
        realitioAnswer,
        2000,
        answerer,
        false,
        { from: governor }
      ),
      "The status should be Ruled."
    );

    await arbitrator.giveAppealableRuling(2, 23, appealCost, appealTimeOut, {
      from: governor,
    }); // Arbitrator's ruling matches the answer in this case.
    await proxy.fundAppeal(questionID, 81, { from: crowdfunder1, value: 500 });
    await time.increase(appealTimeOut + 1);
    await arbitrator.executeRuling(2, { from: governor });

    // Check incorrect inputs.
    await expectRevert(
      proxy.reportAnswer(
        questionID,
        currentHash,
        realitioAnswer,
        2000,
        answerer,
        false,
        { from: governor }
      ),
      "The hash does not match."
    );
    await expectRevert(
      proxy.reportAnswer(
        questionID,
        lastHistoryHash,
        badAnswer,
        2000,
        answerer,
        false,
        { from: governor }
      ),
      "The hash does not match."
    );
    await expectRevert(
      proxy.reportAnswer(
        questionID,
        lastHistoryHash,
        realitioAnswer,
        2001,
        answerer,
        false,
        { from: governor }
      ),
      "The hash does not match."
    );
    await expectRevert(
      proxy.reportAnswer(
        questionID,
        lastHistoryHash,
        realitioAnswer,
        2000,
        governor,
        false,
        { from: governor }
      ),
      "The hash does not match."
    );
    await expectRevert(
      proxy.reportAnswer(
        questionID,
        lastHistoryHash,
        realitioAnswer,
        2000,
        answerer,
        true,
        { from: governor }
      ),
      "The hash does not match."
    );
    //
    await proxy.reportAnswer(
      questionID,
      lastHistoryHash,
      realitioAnswer,
      2000,
      answerer,
      false,
      { from: governor }
    );

    const questionData = await proxy.questions(questionID);
    assert.equal(questionData[1].toNumber(), 3, "Status should be Reported");

    // Check that can't report 2nd time.
    await expectRevert(
      proxy.reportAnswer(
        questionID,
        lastHistoryHash,
        realitioAnswer,
        2000,
        answerer,
        false,
        { from: governor }
      ),
      "The status should be Ruled."
    );

    // Check that withdrawal works with the updated status.
    const oldBalance = await web3.eth.getBalance(crowdfunder1);
    await proxy.withdrawFeesAndRewards(questionID, crowdfunder1, 0, 81, {
      from: governor,
    });
    newBalance = await web3.eth.getBalance(crowdfunder1);
    assert(
      new BN(newBalance).eq(new BN(oldBalance).add(new BN(500))),
      "Withdrawal did not work with Reported status"
    );

    // Check Realitio data.
    assert.equal(
      await realitio.is_pending_arbitration(),
      false,
      "Arbitration flag should not be set"
    );
    const newHash = soliditySha3(
      currentHash,
      realitioAnswer,
      0,
      answerer,
      false
    );
    assert.equal(
      await realitio.getHistoryHash(questionHashed),
      newHash,
      "Realitio hash is incorrect after arbitration"
    );
    assert.equal(
      await realitio.answer(),
      questionData[3].toNumber(),
      "Answer reported incorrectly"
    );
  });

  it("Should report answer correctly if Realitio had incorrect answer", async () => {
    await proxy.requestArbitration(questionHashed, 0, {
      from: requester,
      value: arbitrationCost,
    });

    const realitioAnswer = await realitio.toBytes(22);
    const lastHistoryHash = await realitio.getHistoryHash(questionHashed);
    await realitio.addAnswerToHistory(realitioAnswer, answerer, 2000, false);

    const currentHash = soliditySha3(
      lastHistoryHash,
      realitioAnswer,
      2000,
      answerer,
      false
    );
    await arbitrator.giveRuling(2, 15, { from: governor });
    const questionData = await proxy.questions(questionID);

    await proxy.reportAnswer(
      questionID,
      lastHistoryHash,
      realitioAnswer,
      2000,
      answerer,
      false,
      { from: governor }
    );

    const newHash = soliditySha3(
      currentHash,
      questionData[3],
      0,
      requester,
      false
    ); // In this case requester gets the reward.
    assert.equal(
      await realitio.getHistoryHash(questionHashed),
      newHash,
      "Realitio hash is incorrect after arbitration (requester wins - incorrect answer)"
    );
  });

  it("Should report answer correctly if lastBond = 0", async () => {
    await proxy.requestArbitration(questionHashed, 0, {
      from: requester,
      value: arbitrationCost,
    });

    const realitioAnswer = await realitio.toBytes(22);
    const lastHistoryHash = await realitio.getHistoryHash(questionHashed);
    await realitio.addAnswerToHistory(realitioAnswer, answerer, 0, false);

    const currentHash = soliditySha3(
      lastHistoryHash,
      realitioAnswer,
      0,
      answerer,
      false
    );
    await arbitrator.giveRuling(2, 15, { from: governor });
    const questionData = await proxy.questions(questionID);

    await proxy.reportAnswer(
      questionID,
      lastHistoryHash,
      realitioAnswer,
      0,
      answerer,
      false,
      { from: governor }
    );

    const newHash = soliditySha3(
      currentHash,
      questionData[3],
      0,
      requester,
      false
    ); // In this case requester gets the reward.
    assert.equal(
      await realitio.getHistoryHash(questionHashed),
      newHash,
      "Realitio hash is incorrect after arbitration (requester wins - last bond = 0)"
    );
  });

  it("Should correctly report committed answer", async () => {
    await proxy.requestArbitration(questionHashed, 0, {
      from: requester,
      value: arbitrationCost,
    });

    const commitment = soliditySha3("answer");
    const lastHistoryHash = await realitio.getHistoryHash(questionHashed);
    await realitio.addAnswerToHistory(commitment, answerer, 2000, true);

    const currentHash = soliditySha3(
      lastHistoryHash,
      commitment,
      2000,
      answerer,
      true
    );
    await arbitrator.giveRuling(2, 15, { from: governor });

    const revealedAnswer = await realitio.toBytes(14);
    await realitio.setCommitment(true, revealedAnswer);

    await proxy.reportAnswer(
      questionID,
      lastHistoryHash,
      commitment,
      2000,
      answerer,
      true,
      { from: governor }
    );

    const newHash = soliditySha3(
      currentHash,
      revealedAnswer,
      0,
      answerer,
      false
    );
    assert.equal(
      await realitio.getHistoryHash(questionHashed),
      newHash,
      "Realitio hash is incorrect after arbitration (commitment)"
    );
  });

  it("Should make a correct report if the answer was not revealed", async () => {
    await proxy.requestArbitration(questionHashed, 0, {
      from: requester,
      value: arbitrationCost,
    });

    const commitment = soliditySha3("answer");
    const lastHistoryHash = await realitio.getHistoryHash(questionHashed);
    await realitio.addAnswerToHistory(commitment, answerer, 2000, true);

    const currentHash = soliditySha3(
      lastHistoryHash,
      commitment,
      2000,
      answerer,
      true
    );
    await arbitrator.giveRuling(2, 15, { from: governor });

    await realitio.setCommitment(false, commitment);

    await expectRevert(
      proxy.reportAnswer(
        questionID,
        lastHistoryHash,
        commitment,
        2000,
        answerer,
        true,
        { from: governor }
      ),
      "Still has time to reveal."
    );
    // RealitioMock gives 10 seconds offset to reveal.
    await time.increase(11);

    await proxy.reportAnswer(
      questionID,
      lastHistoryHash,
      commitment,
      2000,
      answerer,
      true,
      { from: governor }
    );
    const questionData = await proxy.questions(questionID);

    const newHash = soliditySha3(
      currentHash,
      questionData[3],
      0,
      requester,
      false
    );
    assert.equal(
      await realitio.getHistoryHash(questionHashed),
      newHash,
      "Realitio hash is incorrect after arbitration (commitment not revealed)"
    );
  });

  it("Should submit evidence and fire the event", async () => {
    await expectRevert(
      proxy.submitEvidence(questionID, "Evidence.json", { from: requester }),
      "The status should be Disputed."
    );
    await proxy.requestArbitration(questionHashed, 0, {
      from: requester,
      value: arbitrationCost,
    });

    txEvidence = await proxy.submitEvidence(questionID, "Evidence.json", {
      from: requester,
    });

    assert.equal(
      txEvidence.logs[0].event,
      "Evidence",
      "Event Evidence has not been created"
    );
    assert.equal(
      txEvidence.logs[0].args._arbitrator,
      arbitrator.address,
      "Event Evidence has wrong arbitrator address"
    );
    assert.equal(
      parseInt(txEvidence.logs[0].args._evidenceGroupID, 10),
      questionID,
      "Event Evidence has wrong evidence group ID"
    );
    assert.equal(
      txEvidence.logs[0].args._party,
      requester,
      "Event Evidence has wrong party"
    );
    assert.equal(
      txEvidence.logs[0].args._evidence,
      "Evidence.json",
      "Event Evidence has wrong evidence URI"
    );

    await arbitrator.giveRuling(2, 15, { from: governor });
    await expectRevert(
      proxy.submitEvidence(questionID, "Evidence.json", { from: requester }),
      "The status should be Disputed."
    );
  });

  it("Should make governance changes", async () => {
    // Winner.
    await expectRevert(
      proxy.changeWinnerMultiplier(2222, { from: other }),
      "The caller must be the governor."
    );
    await proxy.changeWinnerMultiplier(2222, { from: governor });
    multipliers = await proxy.getMultipliers();
    assert.equal(
      multipliers[0].toNumber(),
      2222,
      "Incorrect winnerMultiplier value"
    );
    // Loser.
    await expectRevert(
      proxy.changeLoserMultiplier(2222, { from: other }),
      "The caller must be the governor."
    );
    await proxy.changeLoserMultiplier(3333, { from: governor });
    multipliers = await proxy.getMultipliers();
    assert.equal(
      multipliers[1].toNumber(),
      3333,
      "Incorrect loserMultiplier value"
    );
    // Governor.
    await expectRevert(
      proxy.changeGovernor(other, { from: other }),
      "The caller must be the governor."
    );
    await proxy.changeGovernor(other, { from: governor });
    assert.equal(await proxy.governor(), other, "Incorrect governor address");

    // Metaevidence.
    await expectRevert(
      proxy.changeMetaEvidence("Metaevidence.json", { from: governor }), // 'Other' is governor at this point.
      "The caller must be the governor."
    );
    await expectRevert(
      proxy.changeMetaEvidence("Metaevidence.json", { from: other }),
      "Metaevidence was not set."
    );
    await expectRevert(
      proxy.setMetaEvidence("Metaevidence.json", { from: other }), // The old governor is the deployer.
      "The caller must be the deployer."
    );

    await proxy.setMetaEvidence("Metaevidence.json", { from: governor });
    assert.equal(
      await proxy.deployer(),
      "0x0000000000000000000000000000000000000000",
      "Deployer should be empty"
    );
    await proxy.changeMetaEvidence("Metaevidence.json", { from: other });
    assert.equal(
      (await proxy.metaEvidenceUpdates()).toNumber(),
      1,
      "Incorrect metaEvidenceUpdates value"
    );
  });
});
