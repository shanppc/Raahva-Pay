import { network } from "hardhat";
import { describe, it, beforeEach } from "mocha";
import { expect } from "chai";
import { parse } from "path";

describe("OffRamp", function () {
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

      // Connect as user to create the quote so it belongs to them
      await ramp.connect(user).createQuote(ethers.parseEther("100") ,1);
    });

    it("should verify Offramp usdc Amount and PKR Amount", async function () {
      const { usdcAmount, pkrAmount, fee } = await ramp.quotes(0);
      expect(usdcAmount).to.equal(ethers.parseEther("100"));
      expect(pkrAmount).to.equal(27720n); // must be net pkr
      expect(fee).to.equal(ethers.parseEther("1")); 
    });

    it("should fund the off ramp quote", async function(){
      const userRamp = ramp.connect(user); 
      await userRamp.fundOffRampQuote(0, {value: ethers.parseEther("100")});
      expect(await userRamp.totalCustodied()).to.equal(ethers.parseEther("100"));
      const quote = await userRamp.quotes(0);
      expect(quote.status).to.equal(1n); //Should be funded
    });

    it("should settle OffRamp quote", async function() {
     await ramp.connect(user).fundOffRampQuote(0, {value: ethers.parseEther("100")});

      const domain = {
        name: "Raahva Pay",
        version: "1",
        chainId: Number((await ethers.provider.getNetwork()).chainId),
        verifyingContract: await ramp.getAddress(),
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

      const quote = await ramp.quotes(0);  
      const bankTxIdHash = ethers.keccak256(ethers.toUtf8Bytes("ZBL-TX"));

        const value = {
          quoteId: 0n,
          user: user.address,
          pkrAmount: 27720n,
          bankTxIdHash: bankTxIdHash,
          deadline: quote.settlementDeadline,
        };

      const signature = await operator.signTypedData(domain, types, value);
      expect(await quote.status).to.equal(1n);
      await ramp.settleOffRampQuote(0, bankTxIdHash, signature);

      const updatedQuote = await ramp.quotes(0);
      expect(await updatedQuote.status).to.equal(3n);
      expect(await ramp.totalLiquidity()).to.equal(updatedQuote.usdcAmount - updatedQuote.fee);
      expect(await ramp.totalCustodied()).to.equal(0);
      expect(await ramp.totalFee()).to.equal(updatedQuote.fee);
    });

  });

});
