// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library DataMarketErrors {
    // Existing errors
    error DatasetNotFound(uint256 datasetId);
    error UnauthorizedAccess(address caller);
    error InvalidPrivacyLevel(uint8 level);
    error TransferNotCompleted(bytes32 transferId);
    error TransferTimeout(bytes32 transferId);
    error DisputePeriodNotEnded();
    error ConsensusNotReached();
    error AlreadyCompleted();
    error InvalidAmount();

    // Add new errors needed for ZKDataVerifier
    error InvalidProof();
    error ProofAlreadyVerified();
    error VerificationFailed();
    error InvalidPublicInputs();
    error InvalidInput();

    // Add new errors needed for PrivacyManager
    error TransactionNotFound();
    error MetadataRequired();
    error ProofRequired();
    error InvalidMetadata();
    error InvalidAddress();
    error InvalidAccess();
    error AlreadyAuthorized();
    error TransactionActive();

    // Add new errors needed for P2PDataTransfer
    error TransferAlreadyCompleted();
    error TransferNotFound();
    error InvalidTransfer();
    error TransferExpired();
    error CleanupPeriodNotEnded();

    // Add new errors needed for ConsensusValidator
    error NotValidator();
    error AlreadyValidated();
    error ValidationPeriodEnded();
    error InsufficientValidators();
    error ConsensusAlreadyReached();
    error AlreadyInitialized();
    error InsufficientStake();
    error StakeNotWithdrawn();
    error NoStakeFound();

    // Add new errors needed for DataEscrow
    error InvalidValidator();
    error InvalidMarketplace();
    error InvalidConsensusValidator();
    error EscrowAlreadyExists();
    error EscrowNotFound();
    error FundsAlreadyReleased();
    error FundsAlreadyRefunded();
    error DisputeAlreadyRaised();
    error NoDisputeExists();
    error DisputePeriodExpired();
    error AutoReleasePeriodNotEnded();
    error InvalidFee();
    error NoTokensToWithdraw();
    error TransferFailed();
    error FeeTransferFailed();
}
