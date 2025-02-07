// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../lib/DataMarketErrors.sol";

contract ZKDataVerifier is Ownable, Pausable, ReentrancyGuard {
    using DataMarketErrors for *;

    struct VerificationResult {
        bool isVerified;
        uint256 completenessScore;
        uint256 formatScore;
        string failureReason;
        uint256 timestamp;
    }

    struct ZKProof {
        bytes32 proof;
        bytes32 publicInputs;
        bytes32 commitment;
        uint256 timestamp;
        bool isVerified;
        address verifier;
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
    uint256 public constant MIN_SAMPLE_SIZE = 1024; // 1KB
    uint256 public constant MIN_COMPLETENESS_SCORE = 70;
    uint256 public constant MIN_FORMAT_SCORE = 80;

    event ProofVerified(uint256 indexed datasetId, bytes32 proof, bool success);
    event DatasetVerified(
        uint256 indexed datasetId,
        bool success,
        string failureReason
    );
    event VerificationResultUpdated(
        uint256 indexed datasetId,
        uint256 completenessScore,
        uint256 formatScore
    );

    constructor() Ownable(msg.sender) {}

    function verifyZKProof(
        uint256 _datasetId,
        bytes32 _proof,
        bytes32 _publicInputs
    ) external nonReentrant whenNotPaused returns (bool) {
        if (_proof == bytes32(0)) revert DataMarketErrors.InvalidProof();
        if (usedProofs[_proof]) revert DataMarketErrors.ProofAlreadyVerified();

        // This is where you would implement the actual ZK proof verification
        // For now, we'll simulate the verification process
        bool isValid = verifyProofLogic(_proof, _publicInputs);

        if (isValid) {
            datasetProofs[_datasetId] = ZKProof({
                proof: _proof,
                publicInputs: _publicInputs,
                commitment: keccak256(abi.encodePacked(_proof, _publicInputs)),
                timestamp: block.timestamp,
                isVerified: true,
                verifier: msg.sender
            });

            usedProofs[_proof] = true;
            emit ProofVerified(_datasetId, _proof, true);
        } else {
            emit ProofVerified(_datasetId, _proof, false);
        }

        return isValid;
    }

    function verifyDataset(
        uint256 _datasetId,
        string calldata _dataType,
        uint256 _size,
        bool _hasSample,
        uint256 _sampleSize,
        bytes calldata _formatProof
    ) public nonReentrant whenNotPaused returns (bool) {
        if (_size == 0) revert DataMarketErrors.InvalidProof();
        if (_hasSample && _sampleSize < MIN_SAMPLE_SIZE)
            revert DataMarketErrors.InvalidProof();

        // Store dataset metadata
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

        VerificationResult memory result = VerificationResult({
            isVerified: success,
            completenessScore: completenessScore,
            formatScore: formatScore,
            failureReason: failureReason,
            timestamp: block.timestamp
        });

        verificationResults[_datasetId] = result;
        datasetsMetadata[_datasetId].isVerified = success;

        verificationHistory[_datasetId].push(
            VerificationHistory({
                timestamp: block.timestamp,
                success: success,
                reason: failureReason,
                verifier: msg.sender
            })
        );

        emit DatasetVerified(_datasetId, success, failureReason);
        emit VerificationResultUpdated(
            _datasetId,
            completenessScore,
            formatScore
        );

        return success;
    }

    function verifyMultipleDatasets(
        uint256[] calldata _datasetIds,
        string[] calldata _dataTypes,
        uint256[] calldata _sizes,
        bool[] calldata _hasSamples,
        uint256[] calldata _sampleSizes,
        bytes[] calldata _formatProofs
    ) external nonReentrant whenNotPaused returns (bool[] memory results) {
        if (_datasetIds.length != _dataTypes.length)
            revert DataMarketErrors.InvalidInput();

        results = new bool[](_datasetIds.length);
        for (uint256 i = 0; i < _datasetIds.length; i++) {
            results[i] = verifyDataset(
                _datasetIds[i],
                _dataTypes[i],
                _sizes[i],
                _hasSamples[i],
                _sampleSizes[i],
                _formatProofs[i]
            );
        }
        return results;
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
}
