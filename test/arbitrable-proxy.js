// Import all required modules from openzeppelin-test-helpers
const {
  BN,
  constants,
  expectEvent,
  expectRevert
} = require("@openzeppelin/test-helpers");

// Import preferred chai flavor: both expect and should are supported
const { expect } = require("chai");

const BAP = artifacts.require("ArbitrableProxy");
const Arbitrator = artifacts.require("IArbitrator");
const AutoAppealableArbitrator = artifacts.require("AutoAppealableArbitrator");

const ARBITRATION_COST = 1000000000;

contract(
  "ArbitrableProxy",
  ([sender, receiver, thirdParty, fourthParty, fifthParty]) => {
    before(async function() {
      this.aaa = await AutoAppealableArbitrator.new(1000000000);
      this.bap = await BAP.new(this.aaa.address);
    });

    it("creates a dispute", async function() {
      await this.bap.createDispute("0x00000", "", 2, {
        value: ARBITRATION_COST
      });

      await this.aaa.disputes(0);
    });

    it("it appeals a dispute", async function() {
      await this.aaa.giveAppealableRuling(0, 1, 1000000000, 240);
      assert(new BN("1").eq((await this.aaa.disputes(0)).status));

      await this.bap.fundAppeal(0, 1, {
        value: 2000000000,
        from: thirdParty
      });
      await this.bap.fundAppeal(0, 2, {
        value: 3000000000,
        from: fourthParty
      });

      assert(new BN("0").eq((await this.aaa.disputes(0)).status));
    });

    it("it appeals a dispute once more", async function() {
      await this.aaa.giveAppealableRuling(0, 1, 1000000000, 240);
      assert(new BN("1").eq((await this.aaa.disputes(0)).status));

      await this.bap.fundAppeal(0, 1, {
        value: 1000000000,
        from: thirdParty
      });
      await this.bap.fundAppeal(0, 1, {
        value: 1000000000,
        from: thirdParty
      });

      await this.bap.fundAppeal(0, 2, {
        value: 4000000000,
        from: fourthParty
      }); // 3000000000 is enough, excess 1000000000 will be sent back.
      /* Appeal fully funded */

      const multipliers = await this.bap.getMultipliers();
      assert(multipliers[1] != 0);

      assert(new BN("0").eq((await this.aaa.disputes(0)).status));
    });

    it("batch withdraws fees and rewards", async function() {
      await this.aaa.giveRuling(0, 1);
      console.log((await this.bap.disputes(0)).ruling.words[0]);

      let previousBalanceOfThirdParty = await web3.eth.getBalance(thirdParty);
      let previousBalanceOfFourthParty = await web3.eth.getBalance(fourthParty);
      await this.bap.withdrawFeesAndRewardsForAllRounds(0, thirdParty, [1, 2]);
      await this.bap.withdrawFeesAndRewardsForAllRounds(0, fourthParty, [1, 2]);
      let currentBalanceOfThirdParty = await web3.eth.getBalance(thirdParty);
      let currentBalanceOfFourthParty = await web3.eth.getBalance(fourthParty);

      assert(
        new BN(currentBalanceOfFourthParty).eq(
          new BN(previousBalanceOfFourthParty)
        )
      );

      assert(
        new BN(currentBalanceOfThirdParty).eq(
          new BN(previousBalanceOfThirdParty).add(new BN(8000000000))
        )
      );

      //assert(new BN("1").eq(await this.bap.disputes(0).ruling));
    });

    it.skip("withdraws fees and rewards", async function() {
      await this.aaa.giveRuling(0, 1);

      let previousBalanceOfThirdParty = await web3.eth.getBalance(thirdParty);
      let previousBalanceOfFourthParty = await web3.eth.getBalance(fourthParty);
      await this.bap.withdrawFeesAndRewards(0, thirdParty, 0);
      await this.bap.withdrawFeesAndRewards(0, fourthParty, 0);

      let currentBalanceOfThirdParty = await web3.eth.getBalance(thirdParty);
      let currentBalanceOfFourthParty = await web3.eth.getBalance(fourthParty);
      assert(
        new BN(currentBalanceOfThirdParty).eq(
          new BN(previousBalanceOfThirdParty).add(new BN(1000000000))
        )
      );

      assert(
        new BN(currentBalanceOfFourthParty).eq(
          new BN(previousBalanceOfFourthParty)
        )
      );
    });
  }
);
