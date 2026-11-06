import { network } from "hardhat";
import { describe, it, beforeEach } from "mocha";
import { expect } from "chai";

describe("OnRamp", function () {
  let oracle;
  let ramp;
  let owner, user, operator;
  let ethers;

  beforeEach(async function () {
    ({ ethers } = await network.getOrCreate());
    [owner, user, operator] = await ethers.getSigners();

    const Oracle = await ethers.getContractFactory("Oracle");
    oracle = await Oracle.deploy();
    await oracle.waitForDeployment();

    const Ramp = await ethers.getContractFactory("RaahvaPay");
    ramp = await Ramp.deploy(await oracle.getAddress(), operator.address);
    await ramp.waitForDeployment();
  });

  describe("When a quote is active", function () {
    beforeEach(async function () {
      await oracle.updateRate(ethers.parseUnits("280", 8));
      await ramp.supplyLiquidity({ value: ethers.parseUnits("100", 18) });

      // Connect as user to create the quote so it belongs to them
      await ramp.connect(user).createQuote(28000n, 0);
    });

    it("should create an on-ramp quote", async function () {
      const { usdcAmount } = await ramp.quotes(0);
      expect(usdcAmount).to.equal(ethers.parseUnits("100", 18));
    });

    it("should submit bank proof", async function () {
      const userRamp = ramp.connect(user);
      await userRamp.sumbitBankProof(0, "BANK-TX-001");
      expect(await ramp.bankProofs(0)).to.equal(
        ethers.keccak256(ethers.toUtf8Bytes("BANK-TX-001"))
      );
    });

    it("should successfully settle an on-ramp quote", async function () {
      const domain = {
        name: "Raahva Pay",
        version: "1",
        chainId: Number((await ethers.provider.getNetwork()).chainId),
        verifyingContract: await ramp.getAddress(),
      };

      const types = {
        OnRampPaymentVerification: [
          { name: "quoteId", type: "uint256" },
          { name: "user", type: "address" },
          { name: "pkrAmount", type: "uint256" },
          { name: "bankTxIdHash", type: "bytes32" },
          { name: "deadline", type: "uint256" },
        ],
      };

      const userRamp = ramp.connect(user);

      const txId = "BANK-TX-001";
      await userRamp.sumbitBankProof(0, txId);
      const bankTxIdHash = ethers.keccak256(ethers.toUtf8Bytes(txId));

      const { settlementDeadline, usdcAmount, fee } = await ramp.quotes(0);

      const value = {
        quoteId: 0n,
        user: user.address,
        pkrAmount: 28000n,
        bankTxIdHash: bankTxIdHash,
        deadline: settlementDeadline,
      };

      const signature = await operator.signTypedData(domain, types, value);

      const amountAfterFee = usdcAmount - fee;

      // user receives 99 USDC
      await expect(
        userRamp.verifyAndSettleOnRamp(0, signature)
      ).to.changeEtherBalance(ethers, user, amountAfterFee);

      // fee is recorded
      expect(await ramp.totalFee()).to.equal(fee);

      // totalLiquidity should be zero
      expect(await ramp.totalLiquidity()).to.equal(0n);
    });
  });
});