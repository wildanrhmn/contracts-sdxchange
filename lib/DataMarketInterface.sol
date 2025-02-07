// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

enum VerificationType {
    None,
    Basic,
    ZKProof
}

enum ProofType {
    None,
    Identity,
    Purchase,
    Format
}

enum PrivacyLevel {
    Public,
    Protected,
    Private
}

interface IDataMarketplace {
    function isDatasetListed(
        string memory datasetId
    ) external view returns (bool);

    function verifyDataIntegrity(
        bytes32 deliveryHash,
        bytes32 originalHash
    ) external view returns (bool);
}

interface IDataEscrow {
    function getEscrowState(
        bytes32 escrowId
    ) external view returns (bool exists, bool released, bool disputed);

    function createEscrow(
        address payable seller,
        string memory datasetId,
        bytes32 dataHash
    ) external payable returns (bytes32);

    function confirmDelivery(
        bytes32 transactionId,
        bytes32 deliveryHash
    ) external;

    function releaseFunds(bytes32 transactionId) external;

    function raiseDispute(bytes32 transactionId) external;

    function resolveDispute(bytes32 transactionId, bool refundBuyer) external;
}

interface IConsensusValidator {
    function hasValidConsensus(bytes32 transferId) external view returns (bool);

    function getValidatorCount() external view returns (uint256);

    function initiateValidation(bytes32 transferId) external;

    function validate(bytes32 transferId, bool approved) external;

    function getValidationDetails(
        bytes32 transferId
    )
        external
        view
        returns (
            uint256 approvalCount,
            uint256 rejectionCount,
            bool consensusReached,
            bool approved,
            uint256 validationStartTime,
            uint256 totalValidatorCount
        );
}

interface IP2PDataTransfer {
    function initiateTransfer(
        address receiver,
        bytes32 dataHash,
        bytes memory encryptedKey,
        uint256 totalSize
    ) external returns (bytes32);

    function confirmChunk(bytes32 transferId, uint256 chunkIndex) external;

    function confirmTransfer(
        bytes32 transferId,
        bytes32 deliveryProof
    ) external;

    function getTransferProgress(
        bytes32 transferId
    )
        external
        view
        returns (
            uint256 confirmedChunks,
            uint256 totalChunks,
            bool isCompleted,
            uint256 remainingTime
        );

    function getTransferDetails(
        bytes32 transferId
    )
        external
        view
        returns (
            address sender,
            address receiver,
            bytes32 dataHash,
            bytes memory encryptedKey,
            uint256 startTime,
            uint256 completedTime,
            bool isCompleted,
            bytes32 deliveryProof,
            uint256 chunkSize,
            uint256 totalChunks
        );
}

interface IPrivacyManager {
    function createPrivateTransaction(
        bytes32 txHash,
        bytes memory encryptedMetadata,
        bytes32 zkProof,
        uint8 privacyLevel
    ) external;

    function getTransactionMetadata(
        bytes32 txHash
    )
        external
        view
        returns (
            address creator,
            bytes memory encryptedMetadata,
            uint8 privacyLevel,
            uint256 timestamp,
            bool isRevoked
        );
}

interface IZKDataVerifier {
    function verifyIdentityProof(
        uint256 datasetId,
        bytes32 proof
    ) external returns (bool);

    function verifyPurchaseProof(
        uint256 datasetId,
        bytes32 proof,
        bytes32 purchaseData
    ) external returns (bool);

    function verifyDataset(
        uint256 datasetId,
        string memory dataType,
        uint256 size,
        bool hasSample,
        uint256 sampleSize,
        bytes memory formatProof,
        VerificationType verificationType
    ) external returns (bool);

    function verifyZKProof(
        uint256 datasetId,
        bytes32 proof,
        bytes32 publicInputs,
        ProofType proofType
    ) external returns (bool);
}
