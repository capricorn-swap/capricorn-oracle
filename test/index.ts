import { expect } from "chai";
import { ethers } from "hardhat";

describe("oracle contracts", function () {

    before(async function () {
        this.addrs = await ethers.getSigners();
        this.owner = this.addrs[0].address;
    });

    describe("Deploy and init contracts", function () {
      it("Deploy SlidingWindowOracle", async function () {
        this.SlidingWindowOracle= await ethers.getContractFactory("SlidingWindowOracle");
        this.contract = await this.SlidingWindowOracle.deploy("0x0000000000000000000000000000000000000000", 60*60, 60);
        await this.contract.deployed();
        console.log("deploy SlidingWindowOracle",this.contract.address)
        // expect(await this.contract.owner()).to.equal(this.owner);
      });
    });

});

