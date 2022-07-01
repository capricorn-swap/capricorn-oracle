// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
import { ethers } from "hardhat";

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  // await hre.run('compile');

  // We get the contract to deploy
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);
  console.log("Account balance:", (await deployer.getBalance()).toString());

  let windowSize = 600
  let granularity = 10
  let capricornSwapFactory = ''

  let networkName = process.env['HARDHAT_NETWORK']
  if (networkName == 'cube') {
    capricornSwapFactory = '0x33CB4150f3ADFCD92fbFA3309823A2a242bF280f'  // 主网生产环境
  } else if (networkName == 'cube-testnet') {
    capricornSwapFactory = '0x7a1eba426aa389aac9b410cdfe3cef5d344e043f'  // 测试生产环境
  } else {
    console.error("Not support network:", capricornSwapFactory)
    return;
  }
  console.log("Set swap factory address:", capricornSwapFactory)

  const SlidingWindowOracle = await ethers.getContractFactory("SlidingWindowOracle");
  const contract = await SlidingWindowOracle.deploy(capricornSwapFactory, windowSize, granularity);
  await contract.deployed();
  console.log("SlidingWindowOracle deployed to:", contract.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
