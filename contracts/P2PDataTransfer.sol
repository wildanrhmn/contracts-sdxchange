// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../lib/DataMarketErrors.sol";

contract P2PDataTransfer is ReentrancyGuard, Ownable, Pausable {
    using DataMarketErrors for *;

    struct Transfer {
        bytes32 transferId;
        bytes32 dataHash;
        bytes32 deliveryProof;
        address sender;
        address receiver;
        uint256 startTime;
        uint256 completedTime;
        uint256 chunkSize;
        uint256 totalChunks;
        uint256 confirmedChunkCount;
        bool isCompleted;
        bytes encryptedKey;
        mapping(uint256 => bool) confirmedChunks;
    }

    mapping(bytes32 => Transfer) public transfers;
    uint256 public constant TRANSFER_TIMEOUT = 24 hours;
    uint256 public constant MAX_CHUNK_SIZE = 1024 * 1024;
    uint256 public constant MAX_ENCRYPTED_KEY_SIZE = 1024;
    uint256 public constant CLEANUP_DELAY = 7 days;

    event TransferInitiated(
        bytes32 indexed transferId,
        address indexed sender,
        address indexed receiver,
        uint256 totalChunks
    );
    event TransferCompleted(bytes32 indexed transferId, bytes32 deliveryProof);
    event ChunkConfirmed(bytes32 indexed transferId, uint256 chunkIndex);
    event TransferCancelled(bytes32 indexed transferId, string reason);
    event TransferCleaned(bytes32 indexed transferId, uint256 timestamp);

    constructor() Ownable(msg.sender) {}

    function getTransferDetails(
        bytes32 _transferId
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
        )
    {
        Transfer storage transfer = transfers[_transferId];
        return (
            transfer.sender,
            transfer.receiver,
            transfer.dataHash,
            transfer.encryptedKey,
            transfer.startTime,
            transfer.completedTime,
            transfer.isCompleted,
            transfer.deliveryProof,
            transfer.chunkSize,
            transfer.totalChunks
        );
    }

    function initiateTransfer(
        address _receiver,
        bytes32 _dataHash,
        bytes memory _encryptedKey,
        uint256 _totalSize
    ) external nonReentrant whenNotPaused returns (bytes32) {
        if (_encryptedKey.length > MAX_ENCRYPTED_KEY_SIZE)
            revert DataMarketErrors.InvalidTransfer();
        if (_receiver == address(0) || _receiver == msg.sender)
            revert DataMarketErrors.InvalidTransfer();
        if (_totalSize == 0) revert DataMarketErrors.InvalidTransfer();
        if (_dataHash == bytes32(0)) revert DataMarketErrors.InvalidTransfer();
        if (_encryptedKey.length == 0)
            revert DataMarketErrors.InvalidTransfer();
        if (_totalSize > MAX_CHUNK_SIZE * type(uint16).max)
            revert DataMarketErrors.InvalidTransfer();

        bytes32 transferId = keccak256(
            abi.encodePacked(msg.sender, _receiver, block.timestamp, _dataHash)
        );

        uint256 totalChunks = (_totalSize + MAX_CHUNK_SIZE - 1) /
            MAX_CHUNK_SIZE;

        Transfer storage transfer = transfers[transferId];
        transfer.transferId = transferId;
        transfer.sender = msg.sender;
        transfer.receiver = _receiver;
        transfer.dataHash = _dataHash;
        transfer.encryptedKey = _encryptedKey;
        transfer.startTime = block.timestamp;
        transfer.chunkSize = MAX_CHUNK_SIZE;
        transfer.totalChunks = totalChunks;

        emit TransferInitiated(transferId, msg.sender, _receiver, totalChunks);
        return transferId;
    }

    function confirmChunk(
        bytes32 _transferId,
        uint256 _chunkIndex
    ) external nonReentrant whenNotPaused {
        Transfer storage transfer = transfers[_transferId];
        if (block.timestamp > transfer.startTime + TRANSFER_TIMEOUT)
            revert DataMarketErrors.TransferExpired();
        if (transfer.transferId == bytes32(0))
            revert DataMarketErrors.TransferNotFound();
        if (msg.sender != transfer.receiver)
            revert DataMarketErrors.UnauthorizedAccess(msg.sender);
        if (transfer.isCompleted)
            revert DataMarketErrors.TransferAlreadyCompleted();
        if (_chunkIndex >= transfer.totalChunks)
            revert DataMarketErrors.InvalidTransfer();
        if (!transfer.confirmedChunks[_chunkIndex]) {
            transfer.confirmedChunks[_chunkIndex] = true;
            transfer.confirmedChunkCount++;
        }

        emit ChunkConfirmed(_transferId, _chunkIndex);

        if (transfer.confirmedChunkCount == transfer.totalChunks) {
            transfer.isCompleted = true;
            transfer.completedTime = block.timestamp;
            emit TransferCompleted(_transferId, transfer.dataHash);
        }
    }

    function confirmTransfer(
        bytes32 _transferId,
        bytes32 _deliveryProof
    ) external nonReentrant whenNotPaused {
        Transfer storage transfer = transfers[_transferId];
        if (msg.sender != transfer.receiver)
            revert DataMarketErrors.UnauthorizedAccess(msg.sender);
        if (transfer.isCompleted)
            revert DataMarketErrors.TransferAlreadyCompleted();
        if (transfer.confirmedChunkCount != transfer.totalChunks)
            revert DataMarketErrors.InvalidTransfer();
        if (block.timestamp > transfer.startTime + TRANSFER_TIMEOUT)
            revert DataMarketErrors.TransferExpired();

        transfer.isCompleted = true;
        transfer.completedTime = block.timestamp;
        transfer.deliveryProof = _deliveryProof;

        emit TransferCompleted(_transferId, _deliveryProof);
    }

    function cancelTransfer(
        bytes32 _transferId,
        string calldata _reason
    ) external {
        Transfer storage transfer = transfers[_transferId];
        if (transfer.transferId == bytes32(0))
            revert DataMarketErrors.TransferNotFound();
        if (msg.sender != transfer.sender && msg.sender != transfer.receiver)
            revert DataMarketErrors.UnauthorizedAccess(msg.sender);
        if (transfer.isCompleted)
            revert DataMarketErrors.TransferAlreadyCompleted();

        transfer.isCompleted = true;
        emit TransferCancelled(_transferId, _reason);
    }

    function getTransferProgress(
        bytes32 _transferId
    )
        external
        view
        returns (
            uint256 confirmedChunks,
            uint256 totalChunks,
            bool isCompleted,
            uint256 remainingTime
        )
    {
        Transfer storage transfer = transfers[_transferId];
        if (transfer.transferId == bytes32(0))
            revert DataMarketErrors.TransferNotFound();

        uint256 timeLeft = 0;
        if (
            !transfer.isCompleted &&
            block.timestamp < transfer.startTime + TRANSFER_TIMEOUT
        ) {
            timeLeft =
                (transfer.startTime + TRANSFER_TIMEOUT) -
                block.timestamp;
        }

        return (
            transfer.confirmedChunkCount,
            transfer.totalChunks,
            transfer.isCompleted,
            timeLeft
        );
    }

    function cleanupTransfer(bytes32 _transferId) external {
        Transfer storage transfer = transfers[_transferId];
        if (!transfer.isCompleted)
            revert DataMarketErrors.TransferNotCompleted(_transferId);
        if (block.timestamp < transfer.completedTime + CLEANUP_DELAY)
            revert DataMarketErrors.CleanupPeriodNotEnded();
        delete transfers[_transferId];
        emit TransferCleaned(_transferId, block.timestamp);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
