import { HardhatUserConfig, task, vars } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "hardhat-contract-sizer";

const PRIVATE_KEY = vars.get("PRIVATE_KEY");
const SCROLLSCAN_API_KEY = vars.get("SCROLLSCAN_API_KEY");
const SCROLL_SEPOLIA_URL = vars.get("SCROLL_SEPOLIA_URL");

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true
    },
  },
  paths: {
    sources: "./contracts",
  },
  networks: {
    scrollSepolia: {
      url: SCROLL_SEPOLIA_URL,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
  },
  etherscan: {
    apiKey: {
      scrollSepolia: SCROLLSCAN_API_KEY,
    },
    customChains: [
      {
        network: "scrollSepolia",
        chainId: 534351,
        urls: {
          apiURL: "https://api-sepolia.scrollscan.com/api",
          browserURL: "https://sepolia.scrollscan.com/",
        },
      },
    ],
  },
  contractSizer: {
    alphaSort: true,
    runOnCompile: true,
    disambiguatePaths: false,
  },
};

task(
  "contract-size",
  "Outputs the size of compiled contracts in bytes"
).setAction(async (_, { run }) => {
  await run("compile");
  await run("size-contracts");
});

export default config;
