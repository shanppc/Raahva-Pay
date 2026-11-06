import { network } from "hardhat";
import { describe, it, beforeEach } from "mocha";
import { expect } from "chai";

describe("Ramp", function () {
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

  // Basic Deployment Tests
  it("sets deployer as owner", async function () {
    expect(await ramp.owner()).to.equal(owner.address);
  });

  it("sets oracle correctly", async function () {
    expect(await ramp.oracle()).to.equal(await oracle.getAddress());
  });

  it("sets operator correctly", async function () {
    expect(await ramp.operator()).to.equal(operator.address);
  });

  it("should update 280 PKR /USDC", async function () {
    await oracle.updateRate(ethers.parseUnits("280", 8));
    expect(await oracle.exchangeRate()).to.equal(ethers.parseUnits("280", 8));
  });

  it("should fund the ramp with 100 USDC", async function () {
    await ramp.supplyLiquidity({ value: ethers.parseUnits("100", 18) });
    expect(await ramp.totalLiquidity()).to.equal(ethers.parseUnits("100", 18));
  });

    it("accounting values are zero", async function () {
    expect(await ramp.totalFee()).to.equal(0n);
    expect(await ramp.totalCustodied()).to.equal(0n);
    expect(await ramp.totalLiquidity()).to.equal(0n);
  });

  it("contract starts unpaused", async function () {
    expect(await ramp.paused()).to.equal(false);
  });

}); 