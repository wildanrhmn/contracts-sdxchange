import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const tempAddress = "0x0000000000000000000000000000000000000000";

const DataMarketplaceModule = buildModule("DataMarketplaceModule", (m) => {
  // Deploy UserManager first
  const userManager = m.contract("UserManager", [tempAddress]);

  // Deploy ConsensusValidator
  const consensusValidator = m.contract("ConsensusValidator", [userManager]);

  // Deploy ZKDataVerifier
  const zkDataVerifier = m.contract("ZKDataVerifier");

  // Deploy PrivacyManager
  const privacyManager = m.contract("PrivacyManager");

  // Deploy P2PDataTransfer
  const p2pDataTransfer = m.contract("P2PDataTransfer", [userManager]);

  // Deploy DataEscrow with platform fee
  const platformFee = 250; // 2.5%
  const dataEscrow = m.contract("DataEscrow", [platformFee, userManager]);

  // Deploy DataMarketplace with all dependencies
  const dataMarketplace = m.contract("DataMarketplace", [
    platformFee,
    dataEscrow,
    p2pDataTransfer,
    consensusValidator,
    privacyManager,
    zkDataVerifier,
    userManager
  ]);

  // Setup marketplace in escrow
  m.call(dataEscrow, "setMarketplace", [dataMarketplace]);

  // Setup consensus validator in user manager
  m.call(userManager, "setConsensusValidator", [consensusValidator]);

  return {
    userManager,
    consensusValidator,
    zkDataVerifier,
    privacyManager,
    p2pDataTransfer,
    dataEscrow,
    dataMarketplace
  };
});

export default DataMarketplaceModule;