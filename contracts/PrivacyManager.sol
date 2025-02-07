// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../lib/DataMarketErrors.sol";

contract PrivacyManager is Ownable, Pausable, ReentrancyGuard {
    using DataMarketErrors for *;

    enum PrivacyLevel {
        Public,
        Protected,
        Private,
        StrictlyPrivate
    }

    struct PrivateTransaction {
        bytes32 txHash;
        address creator;
        bytes encryptedMetadata;
        bytes32 zkProof;
        uint8 privacyLevel;
        uint256 timestamp;
        bool isRevoked;
        mapping(address => bool) authorizedUsers;
    }

    struct TransactionAction {
        uint256 timestamp;
        address actor;
        string actionType;
    }

    mapping(bytes32 => PrivateTransaction) public privateTransactions;
    mapping(address => bytes32[]) public userTransactions;
    mapping(bytes32 => TransactionAction[]) private transactionHistory;

    uint256 public constant MIN_ENCRYPTION_LENGTH = 100;
    uint256 public constant MAX_METADATA_SIZE = 1024;
    uint256 public constant CLEANUP_DELAY = 30 days;

    event TransactionCreated(
        bytes32 indexed txHash,
        address indexed creator,
        uint8 privacyLevel
    );
    event AccessGranted(bytes32 indexed txHash, address indexed user);
    event AccessRevoked(bytes32 indexed txHash, address indexed user);
    event MetadataUpdated(bytes32 indexed txHash, bytes newEncryptedMetadata);
    event TransactionRevoked(bytes32 indexed txHash);
    event TransactionCleaned(bytes32 indexed txHash, uint256 timestamp);

    constructor() Ownable(msg.sender) {}

    function isValidPrivacyLevel(uint8 _level) internal pure returns (bool) {
        return _level <= uint8(PrivacyLevel.StrictlyPrivate);
    }

    function createPrivateTransaction(
        bytes32 _txHash,
        bytes memory _encryptedMetadata,
        bytes32 _zkProof,
        uint8 _privacyLevel
    ) external nonReentrant whenNotPaused {
        if (!isValidPrivacyLevel(_privacyLevel))
            revert DataMarketErrors.InvalidPrivacyLevel(_privacyLevel);
        if (_privacyLevel == uint8(PrivacyLevel.StrictlyPrivate)) {
            require(
                _zkProof != bytes32(0) &&
                    _encryptedMetadata.length >= MIN_ENCRYPTION_LENGTH
            );
        }
        if (_encryptedMetadata.length == 0)
            revert DataMarketErrors.MetadataRequired();
        if (_privacyLevel > 1 && _zkProof == bytes32(0))
            revert DataMarketErrors.ProofRequired();
        if (_encryptedMetadata.length > MAX_METADATA_SIZE)
            revert DataMarketErrors.InvalidMetadata();

        PrivateTransaction storage txn = privateTransactions[_txHash];
        txn.txHash = _txHash;
        txn.creator = msg.sender;
        txn.encryptedMetadata = _encryptedMetadata;
        txn.zkProof = _zkProof;
        txn.privacyLevel = _privacyLevel;
        txn.timestamp = block.timestamp;
        txn.authorizedUsers[msg.sender] = true;

        userTransactions[msg.sender].push(_txHash);

        emit TransactionCreated(_txHash, msg.sender, _privacyLevel);
    }

    function grantAccess(
        bytes32 _txHash,
        address _user
    ) external nonReentrant whenNotPaused {
        if (_user == address(0)) revert DataMarketErrors.InvalidAddress();
        if (_user == msg.sender) revert DataMarketErrors.InvalidAccess();
        PrivateTransaction storage txn = privateTransactions[_txHash];
        if (txn.authorizedUsers[_user])
            revert DataMarketErrors.AlreadyAuthorized();
        if (txn.txHash == bytes32(0))
            revert DataMarketErrors.TransactionNotFound();
        if (msg.sender != txn.creator)
            revert DataMarketErrors.UnauthorizedAccess(msg.sender);
        if (txn.isRevoked)
            revert DataMarketErrors.UnauthorizedAccess(msg.sender);

        txn.authorizedUsers[_user] = true;
        emit AccessGranted(_txHash, _user);
    }

    function grantBatchAccess(
        bytes32 _txHash,
        address[] calldata _users
    ) external nonReentrant whenNotPaused {
        PrivateTransaction storage txn = privateTransactions[_txHash];
        if (txn.txHash == bytes32(0))
            revert DataMarketErrors.TransactionNotFound();
        if (msg.sender != txn.creator)
            revert DataMarketErrors.UnauthorizedAccess(msg.sender);
        if (txn.isRevoked)
            revert DataMarketErrors.UnauthorizedAccess(msg.sender);

        for (uint i = 0; i < _users.length; i++) {
            address user = _users[i];
            if (
                user == address(0) ||
                user == msg.sender ||
                txn.authorizedUsers[user]
            ) continue;
            txn.authorizedUsers[user] = true;
            emit AccessGranted(_txHash, user);
        }
    }

    function revokeAccess(
        bytes32 _txHash,
        address _user
    ) external nonReentrant whenNotPaused {
        PrivateTransaction storage txn = privateTransactions[_txHash];
        if (txn.txHash == bytes32(0))
            revert DataMarketErrors.TransactionNotFound();
        if (msg.sender != txn.creator)
            revert DataMarketErrors.UnauthorizedAccess(msg.sender);
        if (_user == txn.creator)
            revert DataMarketErrors.UnauthorizedAccess(msg.sender);

        txn.authorizedUsers[_user] = false;
        emit AccessRevoked(_txHash, _user);
    }

    function updateMetadata(
        bytes32 _txHash,
        bytes memory _newEncryptedMetadata
    ) external nonReentrant whenNotPaused {
        PrivateTransaction storage txn = privateTransactions[_txHash];
        if (txn.txHash == bytes32(0))
            revert DataMarketErrors.TransactionNotFound();
        if (msg.sender != txn.creator)
            revert DataMarketErrors.UnauthorizedAccess(msg.sender);
        if (_newEncryptedMetadata.length == 0)
            revert DataMarketErrors.MetadataRequired();
        if (_newEncryptedMetadata.length > MAX_METADATA_SIZE)
            revert DataMarketErrors.InvalidMetadata();
        if (
            txn.privacyLevel == uint8(PrivacyLevel.StrictlyPrivate) &&
            _newEncryptedMetadata.length < MIN_ENCRYPTION_LENGTH
        ) {
            revert DataMarketErrors.InvalidMetadata();
        }

        txn.encryptedMetadata = _newEncryptedMetadata;
        emit MetadataUpdated(_txHash, _newEncryptedMetadata);
    }

    function revokeTransaction(
        bytes32 _txHash
    ) external nonReentrant whenNotPaused {
        PrivateTransaction storage txn = privateTransactions[_txHash];
        if (txn.txHash == bytes32(0))
            revert DataMarketErrors.TransactionNotFound();
        if (msg.sender != txn.creator)
            revert DataMarketErrors.UnauthorizedAccess(msg.sender);

        txn.isRevoked = true;
        removeUserTransaction(_txHash);
        emit TransactionRevoked(_txHash);
    }

    function hasAccess(
        bytes32 _txHash,
        address _user
    ) external view returns (bool) {
        return privateTransactions[_txHash].authorizedUsers[_user];
    }

    function getUserTransactions(
        address _user
    ) external view returns (bytes32[] memory) {
        return userTransactions[_user];
    }

    function getTransactionMetadata(
        bytes32 _txHash
    )
        external
        view
        returns (
            address creator,
            bytes memory encryptedMetadata,
            uint8 privacyLevel,
            uint256 timestamp,
            bool isRevoked
        )
    {
        PrivateTransaction storage txn = privateTransactions[_txHash];
        if (!txn.authorizedUsers[msg.sender])
            revert DataMarketErrors.UnauthorizedAccess(msg.sender);
        return (
            txn.creator,
            txn.encryptedMetadata,
            txn.privacyLevel,
            txn.timestamp,
            txn.isRevoked
        );
    }

    function _addHistoryEntry(
        bytes32 _txHash,
        string memory _actionType
    ) internal {
        transactionHistory[_txHash].push(
            TransactionAction({
                timestamp: block.timestamp,
                actor: msg.sender,
                actionType: _actionType
            })
        );
    }

    function getTransactionHistory(
        bytes32 _txHash
    ) external view returns (TransactionAction[] memory) {
        PrivateTransaction storage txn = privateTransactions[_txHash];
        if (!txn.authorizedUsers[msg.sender])
            revert DataMarketErrors.UnauthorizedAccess(msg.sender);
        return transactionHistory[_txHash];
    }

    function cleanupTransaction(bytes32 _txHash) external {
        PrivateTransaction storage txn = privateTransactions[_txHash];
        if (!txn.isRevoked) revert DataMarketErrors.TransactionActive();
        if (block.timestamp < txn.timestamp + CLEANUP_DELAY)
            revert DataMarketErrors.CleanupPeriodNotEnded();
        delete privateTransactions[_txHash];
        emit TransactionCleaned(_txHash, block.timestamp);
    }

    function removeUserTransaction(bytes32 _txHash) internal {
        bytes32[] storage userTxns = userTransactions[msg.sender];
        for (uint i = 0; i < userTxns.length; i++) {
            if (userTxns[i] == _txHash) {
                userTxns[i] = userTxns[userTxns.length - 1];
                userTxns.pop();
                break;
            }
        }
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
