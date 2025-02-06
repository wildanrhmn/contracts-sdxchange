// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

interface IDataVerifier {
    struct VerificationResult {
        bool isVerified;
        uint256 completenessScore;
        uint256 formatScore;
        string failureReason;
        uint256 timestamp;
    }

    function verifyDataset(
        uint256 datasetId,
        string calldata dataType,
        uint256 size,
        bool hasSample,
        uint256 sampleSize,
        bytes calldata formatProof
    ) external returns (bool);

    function getVerificationResult(
        uint256 datasetId
    ) external view returns (VerificationResult memory);
}
