// Import all required modules from openzeppelin-test-helpers
const { BN, constants, expectEvent, expectRevert } = require("@openzeppelin/test-helpers");

// Import preferred chai flavor: both expect and should are supported
const { expect } = require("chai");

const AP = artifacts.require("ArbitrableProxy");
const Arbitrator = artifacts.require("IArbitrator");
const AutoAppealableArbitrator = artifacts.require("AutoAppealableArbitrator");

const ARBITRATION_COST = 1000000000;
const LOSER_STAKE_MULTIPLIER = 20000;
const WINNER_STAKE_MULTIPLIER = 10000;
const DIVISOR = 10000;
const NUMBER_OF_RULING_OPTIONS = 5;

contract("ArbitrableProxy", ([sender, receiver, thirdParty, fourthParty, fifthParty]) => {
  before(async function () {
    this.aaa = await AutoAppealableArbitrator.new(ARBITRATION_COST);
    this.ap = await AP.new(this.aaa.address);
  });

  it("creates a dispute", async function () {
    await this.ap.createDispute(this.aaa.address, "0x00000", "", NUMBER_OF_RULING_OPTIONS, {
      value: ARBITRATION_COST,
    });

    await this.aaa.disputes(0);
  });

  it("it appeals a dispute", async function () {
    await this.aaa.giveAppealableRuling(0, 1, ARBITRATION_COST, 240);
    assert(new BN("1").eq((await this.aaa.disputes(0)).status));

    await this.ap.fundAppeal(this.aaa.address, 0, 1, {
      // Fully funded
      value: ARBITRATION_COST * (1 + WINNER_STAKE_MULTIPLIER / DIVISOR),
      from: thirdParty,
    });

    await this.ap.fundAppeal(this.aaa.address, 0, 2, {
      // Fully funded
      value: ARBITRATION_COST * (1 + LOSER_STAKE_MULTIPLIER / DIVISOR),
      from: fourthParty,
    });

    const disputeStatus = (await this.aaa.disputes(0)).status;
    assert(new BN("0").eq(disputeStatus), `Expected disputeStatus 0, actual ${disputeStatus}`);
  });

  it("it appeals the same dispute once more", async function () {
    await this.aaa.giveAppealableRuling(0, 2, ARBITRATION_COST, 240);
    let disputeStatus = (await this.aaa.disputes(0)).status;
    assert(new BN("1").eq(disputeStatus), `Expected disputeStatus 1, actual ${disputeStatus}`);

    await this.ap.fundAppeal(this.aaa.address, 0, 1, {
      value: (ARBITRATION_COST * (1 + LOSER_STAKE_MULTIPLIER / DIVISOR)) / 2,
      from: thirdParty,
    });
    await this.ap.fundAppeal(this.aaa.address, 0, 1, {
      value: (ARBITRATION_COST * (1 + LOSER_STAKE_MULTIPLIER / DIVISOR)) / 2,
      from: fifthParty,
    });

    const previousBalanceOfFourthParty = await web3.eth.getBalance(fourthParty);
    const tx = await this.ap.fundAppeal(this.aaa.address, 0, 2, {
      value: ARBITRATION_COST * (1 + WINNER_STAKE_MULTIPLIER / DIVISOR) + 123456789,
      from: fourthParty,
    }); // 123456789 is excess value, should be sent back.

    const currentBalanceOfFourthParty = await web3.eth.getBalance(fourthParty);
    const balanceDelta = new BN(previousBalanceOfFourthParty).sub(new BN(currentBalanceOfFourthParty));
    assert(balanceDelta.eq(new BN(ARBITRATION_COST * (1 + WINNER_STAKE_MULTIPLIER / DIVISOR)).add(new BN(tx.receipt.gasUsed))), `Expected ${new BN(ARBITRATION_COST * (1 + WINNER_STAKE_MULTIPLIER / DIVISOR)).add(new BN(tx.receipt.gasUsed))}, actual ${balanceDelta}`);

    disputeStatus = (await this.aaa.disputes(0)).status;
    assert(new BN("0").eq(disputeStatus), `Expected disputeStatus 0, actual ${disputeStatus}`);
  });

  it("batch withdraws fees and rewards", async function () {
    await this.aaa.giveRuling(0, 3);

    const previousBalanceOfThirdParty = await web3.eth.getBalance(thirdParty);
    const previousBalanceOfFourthParty = await web3.eth.getBalance(fourthParty);
    const previousBalanceOfFifthParty = await web3.eth.getBalance(fifthParty);

    await this.ap.withdrawFeesAndRewardsForAllRounds(this.aaa.address, 0, thirdParty, [...Array(NUMBER_OF_RULING_OPTIONS + 1).keys()]);
    await this.ap.withdrawFeesAndRewardsForAllRounds(this.aaa.address, 0, fourthParty, [...Array(NUMBER_OF_RULING_OPTIONS + 1).keys()]);
    await this.ap.withdrawFeesAndRewardsForAllRounds(this.aaa.address, 0, fifthParty, [...Array(NUMBER_OF_RULING_OPTIONS + 1).keys()]);

    const currentBalanceOfThirdParty = await web3.eth.getBalance(thirdParty);
    const currentBalanceOfFourthParty = await web3.eth.getBalance(fourthParty);
    const currentBalanceOfFifthParty = await web3.eth.getBalance(fifthParty);

    const expectedDeltaOfThirdParty = 1600000000 + 1200000000;
    const expectedDeltaOfFourthParty = 2400000000 + 1600000000;
    const expectedDeltaOfFifthParty = 1200000000;

    const actualDeltaOfThirdParty = new BN(currentBalanceOfThirdParty).sub(new BN(previousBalanceOfThirdParty));
    const actualDeltaOfFourthParty = new BN(currentBalanceOfFourthParty).sub(new BN(previousBalanceOfFourthParty));
    const actualDeltaOfFifthParty = new BN(currentBalanceOfFifthParty).sub(new BN(previousBalanceOfFifthParty));

    assert(new BN(expectedDeltaOfThirdParty).eq(actualDeltaOfThirdParty), `Expected ${expectedDeltaOfThirdParty}, actual ${actualDeltaOfThirdParty}`);
    assert(new BN(expectedDeltaOfFourthParty).eq(actualDeltaOfFourthParty), `Expected ${expectedDeltaOfFourthParty}, actual ${actualDeltaOfFourthParty}`);
    assert(new BN(expectedDeltaOfFifthParty).eq(actualDeltaOfFifthParty), `Expected ${expectedDeltaOfFifthParty}, actual ${actualDeltaOfFifthParty}`);
  });
});
