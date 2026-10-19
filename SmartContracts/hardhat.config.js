import { defineConfig, configVariable } from "hardhat/config";
import hardhatKeystore from "@nomicfoundation/hardhat-keystore";

export default defineConfig({
  plugins: [hardhatKeystore],
  solidity: "0.8.30",
  networks: {
    sepolia: {
      type: "http",  
      chainType: "l1",   
      url: "https://rpc.sepolia.org",
      accounts: [configVariable("PRIVATE_KEY")], 
    },
  },
});