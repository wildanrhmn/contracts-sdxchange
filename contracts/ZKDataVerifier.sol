// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../lib/DataMarketInterface.sol";
import "../lib/DataMarketErrors.sol";

contract ZKDataVerifier is IZKDataVerifier, Ownable, Pausable, ReentrancyGuard {
    using DataMarketErrors for *;

    struct VerificationResult {
        bool isVerified;
        uint256 completenessScore;
        uint256 formatScore;
        string failureReason;
        uint256 timestamp;
        VerificationType verificationType;
    }

    struct ZKProof {
        bytes32 proof;
        bytes32 publicInputs;
        bytes32 commitment;
        uint256 timestamp;
        bool isVerified;
        address verifier;
        ProofType proofType;
    }

    struct DatasetMetadata {
        string dataType;
        uint256 size;
        bool hasSample;
        uint256 sampleSize;
        bytes formatProof;
        uint256 lastVerification;
        bool isVerified;
    }

    struct VerificationHistory {
        uint256 timestamp;
        bool success;
        string reason;
        address verifier;
    }

    mapping(uint256 => ZKProof) public datasetProofs;
    mapping(uint256 => VerificationResult) public verificationResults;
    mapping(uint256 => DatasetMetadata) public datasetsMetadata;
    mapping(bytes32 => bool) public usedProofs;
    mapping(uint256 => VerificationHistory[]) public verificationHistory;

    uint256 public constant VERIFICATION_COOLDOWN = 1 hours;
    uint256 public constant MIN_SAMPLE_SIZE = 1024;
    uint256 public constant MIN_COMPLETENESS_SCORE = 70;
    uint256 public constant MIN_FORMAT_SCORE = 80;

    event ProofVerified(uint256 indexed datasetId, bytes32 proof, bool success);
    event DatasetVerified(uint256 indexed datasetId, bool success, string failureReason);
    event VerificationResultUpdated(uint256 indexed datasetId, uint256 completenessScore, uint256 formatScore);
    event IdentityVerified(uint256 indexed datasetId, address indexed user, bool success);
    event PurchaseVerified(uint256 indexed datasetId, address indexed buyer, bool success);
    event FormatVerified(uint256 indexed datasetId, bool success);

    constructor() Ownable(msg.sender) {}

    function verifyIdentityProof(
        uint256 _datasetId,
        bytes32 _proof
    ) external override nonReentrant whenNotPaused returns (bool) {
        if (_proof == bytes32(0)) revert DataMarketErrors.InvalidProof();
        if (usedProofs[_proof]) revert DataMarketErrors.ProofAlreadyVerified();

        bool isValid = verifyProofLogic(_proof, bytes32(0), ProofType.Identity);

        if (isValid) {
            datasetProofs[_datasetId] = ZKProof({
                proof: _proof,
                publicInputs: bytes32(0),
                commitment: keccak256(abi.encodePacked(_proof)),
                timestamp: block.timestamp,
                isVerified: true,
                verifier: msg.sender,
                proofType: ProofType.Identity
            });

            usedProofs[_proof] = true;
            emit ProofVerified(_datasetId, _proof, true);
            emit IdentityVerified(_datasetId, msg.sender, true);
        }

        return isValid;
    }

    function verifyPurchaseProof(
        uint256 _datasetId,
        bytes32 _proof,
        bytes32 _purchaseData
    ) external override nonReentrant whenNotPaused returns (bool) {
        if (_proof == bytes32(0)) revert DataMarketErrors.InvalidProof();
        if (usedProofs[_proof]) revert DataMarketErrors.ProofAlreadyVerified();

        bool isValid = verifyProofLogic(_proof, _purchaseData, ProofType.Purchase);

        if (isValid) {
            datasetProofs[_datasetId] = ZKProof({
                proof: _proof,
                publicInputs: _purchaseData,
                commitment: keccak256(abi.encodePacked(_proof, _purchaseData)),
                timestamp: block.timestamp,
                isVerified: true,
                verifier: msg.sender,
                proofType: ProofType.Purchase
            });

            usedProofs[_proof] = true;
            emit ProofVerified(_datasetId, _proof, true);
            emit PurchaseVerified(_datasetId, msg.sender, true);
        }

        return isValid;
    }

    function verifyProofLogic(
        bytes32 _proof,
        bytes32 _publicInputs,
        ProofType _proofType
    ) internal pure returns (bool) {
        if (_proof == bytes32(0)) return false;

        // Different verification logic based on proof type
        if (_proofType == ProofType.Identity) {
            // Verify identity-related proofs
            // Example: age verification, jurisdiction check, etc.
            return verifyIdentityLogic(_proof);
        } else if (_proofType == ProofType.Purchase) {
            // Verify purchase-related proofs
            // Example: data integrity, payment verification, etc.
            return verifyPurchaseLogic(_proof, _publicInputs);
        } else if (_proofType == ProofType.Format) {
            // Verify format-related proofs
            // Example: data structure, schema validation, etc.
            return verifyFormatLogic(_proof);
        }

        return false;
    }

    function verifyDataset(
        uint256 _datasetId,
        string memory _dataType,
        uint256 _size,
        bool _hasSample,
        uint256 _sampleSize,
        bytes memory _formatProof,
        VerificationType _verificationType
    ) external override nonReentrant whenNotPaused returns (bool) {
        if (_size == 0) revert DataMarketErrors.InvalidProof();
        if (_hasSample && _sampleSize < MIN_SAMPLE_SIZE)
            revert DataMarketErrors.InvalidProof();

        datasetsMetadata[_datasetId] = DatasetMetadata({
            dataType: _dataType,
            size: _size,
            hasSample: _hasSample,
            sampleSize: _sampleSize,
            formatProof: _formatProof,
            lastVerification: block.timestamp,
            isVerified: false
        });

        (
            bool success,
            string memory failureReason,
            uint256 completenessScore,
            uint256 formatScore
        ) = verifyDatasetLogic(_datasetId);

        verificationResults[_datasetId] = VerificationResult({
            isVerified: success,
            completenessScore: completenessScore,
            formatScore: formatScore,
            failureReason: failureReason,
            timestamp: block.timestamp,
            verificationType: _verificationType
        });

        datasetsMetadata[_datasetId].isVerified = success;

        emit DatasetVerified(_datasetId, success, failureReason);
        emit VerificationResultUpdated(
            _datasetId,
            completenessScore,
            formatScore
        );

        return success;
    }

    function verifyZKProof(
        uint256 _datasetId,
        bytes32 _proof,
        bytes32 _publicInputs,
        ProofType _proofType
    ) external override nonReentrant whenNotPaused returns (bool) {
        if (_proof == bytes32(0)) revert DataMarketErrors.InvalidProof();
        if (usedProofs[_proof]) revert DataMarketErrors.ProofAlreadyVerified();

        bool isValid = verifyProofLogic(_proof, _publicInputs);

        if (isValid) {
            datasetProofs[_datasetId] = ZKProof({
                proof: _proof,
                publicInputs: _publicInputs,
                commitment: keccak256(abi.encodePacked(_proof, _publicInputs)),
                timestamp: block.timestamp,
                isVerified: true,
                verifier: msg.sender,
                proofType: _proofType
            });

            usedProofs[_proof] = true;
            emit ProofVerified(_datasetId, _proof, true);
        } else {
            emit ProofVerified(_datasetId, _proof, false);
        }

        return isValid;
    }

    function getVerificationResult(
        uint256 _datasetId
    ) external view returns (VerificationResult memory) {
        if (verificationResults[_datasetId].timestamp == 0)
            revert DataMarketErrors.DatasetNotFound(_datasetId);
        return verificationResults[_datasetId];
    }

    function verifyProofLogic(
        bytes32 _proof,
        bytes32 _publicInputs
    ) internal pure returns (bool) {
        // Add more sophisticated validation
        if (_proof == bytes32(0) || _publicInputs == bytes32(0)) return false;

        // Add additional checks based on your ZK system requirements
        // For example, verify proof structure, validate input format, etc.

        return true;
    }

    function verifyDatasetLogic(
        uint256 _datasetId
    )
        internal
        view
        returns (
            bool success,
            string memory failureReason,
            uint256 completenessScore,
            uint256 formatScore
        )
    {
        DatasetMetadata storage metadata = datasetsMetadata[_datasetId];

        completenessScore = calculateCompletenessScore(metadata);
        formatScore = calculateFormatScore(metadata);

        if (completenessScore < MIN_COMPLETENESS_SCORE) {
            return (
                false,
                "Insufficient completeness score",
                completenessScore,
                formatScore
            );
        }

        if (formatScore < MIN_FORMAT_SCORE) {
            return (
                false,
                "Insufficient format score",
                completenessScore,
                formatScore
            );
        }

        return (true, "", completenessScore, formatScore);
    }

    function calculateCompletenessScore(
        DatasetMetadata storage _metadata
    ) internal view returns (uint256) {
        uint256 score = 0;

        if (bytes(_metadata.dataType).length > 0) score += 20;
        if (_metadata.size > 0) score += 20;
        if (_metadata.hasSample) score += 20;

        if (_metadata.sampleSize >= MIN_SAMPLE_SIZE) score += 20;
        if (_metadata.formatProof.length > 0) score += 20;

        return score;
    }

    function calculateFormatScore(
        DatasetMetadata storage _metadata
    ) internal view returns (uint256) {
        uint256 score = 0;

        if (bytes(_metadata.dataType).length <= 100) score += 25;
        if (_metadata.size <= 1e12) score += 25;
        if (_metadata.sampleSize <= _metadata.size) score += 25;
        if (_metadata.lastVerification <= block.timestamp) score += 25;

        return score;
    }

    function updateVerificationResult(
        uint256 _datasetId,
        uint256 _completenessScore,
        uint256 _formatScore,
        string calldata _failureReason
    ) external onlyOwner {
        if (verificationResults[_datasetId].timestamp == 0)
            revert DataMarketErrors.DatasetNotFound(_datasetId);

        VerificationResult storage result = verificationResults[_datasetId];
        result.completenessScore = _completenessScore;
        result.formatScore = _formatScore;
        result.failureReason = _failureReason;
        result.timestamp = block.timestamp;

        emit VerificationResultUpdated(
            _datasetId,
            _completenessScore,
            _formatScore
        );
    }

    function getDatasetMetadata(
        uint256 _datasetId
    ) external view returns (DatasetMetadata memory) {
        return datasetsMetadata[_datasetId];
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Add helper functions for different verification types
    function verifyIdentityLogic(bytes32 _proof) internal pure returns (bool) {
        // Implement identity verification logic
        // For now, return true if proof is not empty
        return _proof != bytes32(0);
    }

    function verifyPurchaseLogic(
        bytes32 _proof,
        bytes32 _publicInputs
    ) internal pure returns (bool) {
        // Implement purchase verification logic
        // For now, basic check that both inputs are valid
        return _proof != bytes32(0) && _publicInputs != bytes32(0);
    }

    function verifyFormatLogic(bytes32 _proof) internal pure returns (bool) {
        // Implement format verification logic
        // For now, return true if proof is not empty
        return _proof != bytes32(0);
    }
}
