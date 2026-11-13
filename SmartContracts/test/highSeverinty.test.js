import { expect } from "chai";
import { network } from "hardhat";

// Regression suite for the 3 High-severity bugs
//   1       bank-tx-id squatting via a shared usedBankTxIds mapping
//   2       oracle had no bounds on updateRate()
//   3    reservedLiquidity could be locked forever for free (only the
//             quote's own `user` could call expireQuote, and ProofSubmitted
//             quotes had no exit at all)

describe("RaahvaPay — High-severity regression suite", function () {
  let ethers, networkHelpers;
  let oracle, raahva;
  let owner, operator, attacker, victim, rando;
  let raahvaAddress, chainId;

  const RATE_PRECISION = 10n ** 8n;
  const RATE = 280n * RATE_PRECISION; // 280 PKR per 1 USDC

  const RampType = { OnRamp: 0, OffRamp: 1 };
  const Status = {
    QuoteCreated: 0n, Funded: 1n, ProofSubmitted: 2n,
    Settled: 3n, Refunded: 4n, Expired: 5n,
  };

  beforeEach(async function () {
    ({ ethers, networkHelpers } = await network.create());
    [owner, operator, attacker, victim, rando] = await ethers.getSigners();

    oracle = await ethers.deployContract("Oracle", [owner.address]);
    await oracle.connect(owner).updateRate(RATE);

    raahva = await ethers.deployContract("RaahvaPay", [await oracle.getAddress(), operator.address]);
    raahvaAddress = await raahva.getAddress();
    chainId = (await ethers.provider.getNetwork()).chainId;

    await raahva.connect(owner).supplyLiquidity({ value: ethers.parseEther("1000") });
  });

  async function signOffRamp(quoteId, user, pkrAmount, bankTxIdHash, deadline) {
    const domain = { name: "Raahva Pay", version: "1", chainId, verifyingContract: raahvaAddress };
    const types = {
      OffRampPaymentVerification: [
        { name: "quoteId", type: "uint256" },
        { name: "user", type: "address" },
        { name: "pkrAmount", type: "uint256" },
        { name: "bankTxIdHash", type: "bytes32" },
        { name: "deadline", type: "uint256" },
      ],
    };
    return operator.signTypedData(domain, types, { quoteId, user, pkrAmount, bankTxIdHash, deadline });
  }

  // ------------------------------------------------------------------------
  describe("H-1 (fixed): bank-tx-id squatting", function () {
    it("an on-ramp proof using the same string no longer blocks off-ramp settlement", async function () {
      const offRampAmount = ethers.parseEther("10");

      await raahva.connect(attacker).createQuote(offRampAmount, RampType.OffRamp);
      const offRampQuoteId = 0n;
      await raahva.connect(attacker).fundOffRampQuote(offRampQuoteId, { value: offRampAmount });

      const realBankTxId = "REAL-BANK-TX-2026-00917";
      const realBankTxIdHash = ethers.keccak256(ethers.toUtf8Bytes(realBankTxId));

      const onRampPkrAmount = 3000n;
      await raahva.connect(attacker).createQuote(onRampPkrAmount, RampType.OnRamp);
      await raahva.connect(attacker).submitOnRampBankProof(1, realBankTxId);

      expect(await raahva.usedOnRampBankTxIds(realBankTxIdHash)).to.equal(false);
      expect(await raahva.usedOffRampBankTxIds(realBankTxIdHash)).to.equal(false);

      const quote = await raahva.quotes(offRampQuoteId);
      const signature = await signOffRamp(
        offRampQuoteId, attacker.address, quote.pkrAmount, realBankTxIdHash, quote.settlementDeadline
      );

      // Previously reverted with TxIdAlreadyUsed. Now succeeds.
      await raahva.connect(operator).settleOffRampQuote(offRampQuoteId, realBankTxIdHash, signature);

      expect((await raahva.quotes(offRampQuoteId)).status).to.equal(Status.Settled);
      expect(await raahva.usedOffRampBankTxIds(realBankTxIdHash)).to.equal(true);
    });
  });

  // ------------------------------------------------------------------------
  describe("H-3 (fixed): oracle rate bounds", function () {
    it("rejects rates outside [100, 1000] PKR/USDC and accepts rates inside it", async function () {
      await expect(
        oracle.connect(owner).updateRate(99n * RATE_PRECISION)
      ).to.be.revertedWithCustomError(oracle, "RateOutOfBounds");

      await expect(
        oracle.connect(owner).updateRate(1001n * RATE_PRECISION)
      ).to.be.revertedWithCustomError(oracle, "RateOutOfBounds");

      await oracle.connect(owner).updateRate(500n * RATE_PRECISION);
      expect(await oracle.exchangeRate()).to.equal(500n * RATE_PRECISION);
    });
  });

  // ------------------------------------------------------------------------
  describe("New-H1 (fixed): reservedLiquidity can no longer be locked forever", function () {
    it("lets anyone sweep an attacker's abandoned QuoteCreated reservations", async function () {
      const pkrFor5Ether = 5n * 280n; // usdcAmount == 5 ether at RATE

      for (let i = 0; i < 4; i++) {
        await raahva.connect(attacker).createQuote(pkrFor5Ether, RampType.OnRamp);
      }
      expect(await raahva.reservedLiquidity()).to.equal(ethers.parseEther("20"));

      await networkHelpers.time.increase(601); // past the 10-minute expireAt

      // A completely unrelated account sweeps the attacker's abandoned quotes.
      for (let i = 0; i < 4; i++) {
        await raahva.connect(rando).expireQuote(i);
      }

      expect(await raahva.reservedLiquidity()).to.equal(0n);
      await raahva.connect(victim).createQuote(pkrFor5Ether, RampType.OnRamp); // liquidity is free again
    });

    it("lets anyone sweep a ProofSubmitted quote the operator never engages with, but only after a grace window", async function () {
      const pkrFor5Ether = 5n * 280n;
      await raahva.connect(attacker).createQuote(pkrFor5Ether, RampType.OnRamp);
      await raahva.connect(attacker).submitOnRampBankProof(0, "garbage-proof-no-real-payment");

      await networkHelpers.time.increase(601); // past the (first) settlementDeadline

      await expect(raahva.connect(rando).expireQuote(0))
        .to.be.revertedWithCustomError(raahva, "SettlementDeadlineNotPassed");

      await networkHelpers.time.increase(601);
      await raahva.connect(rando).expireQuote(0);

      expect((await raahva.quotes(0)).status).to.equal(Status.Expired);
      expect(await raahva.reservedLiquidity()).to.equal(0n);
    });
  });
});