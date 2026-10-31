import { defineConfig, configVariable } from "hardhat/config";

import hardhatKeystore from "@nomicfoundation/hardhat-keystore";
import hardhatEthers from "@nomicfoundation/hardhat-ethers";
import hardhatTypechain from "@nomicfoundation/hardhat-typechain";
import hardhatMocha from "@nomicfoundation/hardhat-mocha";
import hardhatEthersChaiMatchers from "@nomicfoundation/hardhat-ethers-chai-matchers";
import hardhatNetworkHelpers from "@nomicfoundation/hardhat-network-helpers";

export default defineConfig({
  plugins: [
    hardhatKeystore,
    hardhatEthers,
    hardhatTypechain,
    hardhatMocha,
    hardhatEthersChaiMatchers,
    hardhatNetworkHelpers,
  ],

  solidity: "0.8.30",

  networks: {
    Arc_Testnet: {
      type: "http",
      chainType: "l1",
      url: "https://rpc.testnet.arc.network",
      accounts: [configVariable("PRIVATE_KEY")],
    },
  },
});
