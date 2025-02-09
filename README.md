# SecureData Exchanges

A decentralized data marketplace smart contract system for secure peer-to-peer data trading.

## Overview

SecureData Exchanges is a blockchain-based platform that enables secure and transparent trading of datasets between sellers and buyers. The system incorporates multiple layers of security, privacy controls, and verification mechanisms to ensure data integrity and fair transactions.

## Key Features

- **Decentralized Data Trading**: Peer-to-peer marketplace for buying and selling datasets
- **Privacy Controls**: Configurable privacy levels and access management for datasets
- **Secure Transfers**: Encrypted data transfer with proof-of-delivery verification  
- **Dispute Resolution**: Built-in escrow and dispute handling mechanisms
- **Data Verification**: ZK-proof verification and consensus-based validation
- **Flexible Pricing**: Sellers can set and update dataset prices
- **Access Management**: Granular control over dataset access permissions

## Core Components

- **DataMarketplace.sol**: Main marketplace contract handling listings, purchases and transfers
- **DataEscrow.sol**: Manages secure payment escrow between parties
- **P2PDataTransfer.sol**: Handles encrypted peer-to-peer data transfers
- **ConsensusValidator.sol**: Validates dataset integrity through consensus
- **PrivacyManager.sol**: Controls dataset privacy and access levels
- **ZKDataVerifier.sol**: Zero-knowledge proof verification for datasets

## Key Functions

- `listDataset()`: List a new dataset for sale with metadata and pricing
- `purchaseDataset()`: Purchase access to a dataset
- `confirmDelivery()`: Confirm successful dataset delivery
- `updatePrivacyLevel()`: Modify dataset privacy settings
- `grantAccess()`: Grant buyer access to private datasets
- `resolveDispute()`: Handle transaction disputes

## Security Features

- Reentrancy protection
- Access controls
- Pausable functionality
- Secure fund handling
- Data encryption
- Zero-knowledge proofs
- Multi-party consensus

## License

MIT License

## Deployed Contracts (Scroll Sepolia)

- **ConsensusValidator**: [0xa95fF9d87cE9A7A21d8DE210Cf16d48F6c65db3e](https://sepolia.scrollscan.com/address/0xa95fF9d87cE9A7A21d8DE210Cf16d48F6c65db3e)
- **PrivacyManager**: [0x7ec6bbDa5ae3984530Bb708Ca4C91F1fa5c55278](https://sepolia.scrollscan.com/address/0x7ec6bbDa5ae3984530Bb708Ca4C91F1fa5c55278)
- **UserManager**: [0x45e0741bf4f734A827F4f5804b5499540C066Ffa](https://sepolia.scrollscan.com/address/0x45e0741bf4f734A827F4f5804b5499540C066Ffa)
- **ZKDataVerifier**: [0x51B9e070f9D1E55552008d65C295D3245f90d675](https://sepolia.scrollscan.com/address/0x51B9e070f9D1E55552008d65C295D3245f90d675)
- **DataEscrow**: [0x9A46FA636ED0B57802102F5a185067a094292154](https://sepolia.scrollscan.com/address/0x9A46FA636ED0B57802102F5a185067a094292154)
- **P2PDataTransfer**: [0x4D95a59f2f622d8D662e60cA954B7E9edD12bBCb](https://sepolia.scrollscan.com/address/0x4D95a59f2f622d8D662e60cA954B7E9edD12bBCb)
- **DataMarketplace**: [0xBa619F28c5E9042e260b308808463c658835Fe7c](https://sepolia.scrollscan.com/address/0xBa619F28c5E9042e260b308808463c658835Fe7c)

