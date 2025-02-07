// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./DataEscrow.sol";
import "./P2PDataTransfer.sol";
import "./ConsensusValidator.sol";
import "./PrivacyManager.sol";
import "./ZKDataVerifier.sol";
import "../lib/DataMarketErrors.sol";
import "../lib/DataMarketInterface.sol";

contract DataMarketplace is
    IDataMarketplace,
    ReentrancyGuard,
    Ownable,
    Pausable
{
    using DataMarketErrors for *;

    PrivacyLevel public constant MAX_PRIVACY_LEVEL = PrivacyLevel.Private;
    uint8 public constant CONSENSUS_THRESHOLD = 3;
    uint256 public constant TRANSFER_TIMEOUT = 24 hours;
    uint256 public constant DISPUTE_PERIOD = 3 days;
    uint256 public constant EMERGENCY_PERIOD = 7 days;

    IDataEscrow public escrow;
    IP2PDataTransfer public transferProtocol;
    IConsensusValidator public consensusManager;
    IPrivacyManager public privacyManager;
    IZKDataVerifier public zkVerifier;

    struct Dataset {
        // Basic info
        address seller;
        string metadataURI;
        string sampleDataURI;
        string dataType;
        uint256 size;
        // Status & metrics
        bool isActive;
        uint256 price;
        uint256 totalSales;
        uint256 validationScore;
        // Security & verification
        bytes encryptedKey;
        bytes32 dataHash;
        bytes formatProof;
        bytes32 zkVerificationKey;
        bytes32 transferId;
        PrivacyLevel privacyLevel;
        VerificationType verificationType;
    }

    struct Purchase {
        // Basic info
        address buyer;
        uint256 timestamp;
        bytes32 escrowId;
        // Status flags
        bool completed;
        bool disputed;
        bool zkVerified;
        bool accessGranted;
        // Verification data
        bytes32 accessProofHash;
        uint8 consensusStatus;
        bytes32 zkProof;
        bytes32 transferStatus;
    }

    struct Transfer {
        // Identifiers
        bytes32 transferId;
        uint256 datasetId;
        // Participants
        address sender;
        address receiver;
        // Timing & status
        uint256 startTime;
        uint256 completedTime;
        bool isCompleted;
    }

    mapping(uint256 => Dataset) public datasets;
    mapping(uint256 => mapping(address => Purchase)) public purchases;
    mapping(address => uint256[]) public userDatasets;
    mapping(bytes32 => uint256) public escrowToDataset;
    mapping(uint256 => mapping(address => bool)) public authorizedBuyers;
    mapping(bytes32 => Transfer) public transfers;
    uint256 public datasetCount;
    uint256 public platformFee;

    event DatasetListed(uint256 indexed datasetId, address indexed seller, uint256 price);
    event DatasetPurchased(uint256 indexed datasetId, address indexed buyer, bytes32 escrowId);
    event DatasetUpdated(uint256 indexed datasetId, uint256 newPrice, bool isActive);
    event DisputeRaised(uint256 indexed datasetId, address indexed buyer);
    event DisputeResolved(uint256 indexed datasetId, address indexed buyer, bool buyerRefunded);
    event AccessGranted(uint256 indexed datasetId, address indexed buyer);
    event AccessRevoked(uint256 indexed datasetId, address indexed buyer);
    event TransferInitiated(bytes32 indexed transferId, uint256 indexed datasetId);
    event TransferCompleted(bytes32 indexed transferId, uint256 indexed datasetId);
    event ZKProofVerified(uint256 indexed datasetId, address indexed buyer, bool success);
    event ConsensusStatusUpdated(uint256 indexed datasetId, uint8 status);
    event PrivacyLevelChanged(uint256 indexed datasetId, uint8 newLevel);
    event MetadataUpdated(uint256 indexed datasetId, string newMetadataURI);
    event EmergencyWithdrawal(uint256 indexed datasetId, address indexed user);
    event TransferTimedOut(bytes32 indexed transferId, uint256 indexed datasetId);

    constructor(
        uint256 _platformFee,
        address _escrowAddress,
        address _transferAddress,
        address _consensusAddress,
        address _privacyAddress,
        address _zkVerifierAddress
    ) Ownable(msg.sender) {
        platformFee = _platformFee;
        escrow = IDataEscrow(_escrowAddress);
        transferProtocol = IP2PDataTransfer(_transferAddress);
        consensusManager = IConsensusValidator(_consensusAddress);
        privacyManager = IPrivacyManager(_privacyAddress);
        zkVerifier = IZKDataVerifier(_zkVerifierAddress);
    }

    function isDatasetListed(
        string memory _datasetId
    ) external view override returns (bool) {
        uint256 id = uint256(keccak256(bytes(_datasetId)));

        Dataset storage dataset = datasets[id];
        return dataset.seller != address(0) && dataset.isActive;
    }

    function verifyDataIntegrity(
        bytes32 _deliveryHash,
        bytes32 _originalHash
    ) external view override returns (bool) {
        bool found = false;
        uint256 datasetId;

        for (uint256 i = 0; i < datasetCount; i++) {
            if (datasets[i].dataHash == _originalHash) {
                found = true;
                datasetId = i;
                break;
            }
        }

        if (!found) return false;

        Dataset storage dataset = datasets[datasetId];
        return dataset.isActive && _deliveryHash == dataset.dataHash;
    }

    function checkTransferTimeout(bytes32 _transferId) external nonReentrant {
        Transfer storage transfer = transfers[_transferId];
        if (transfer.isCompleted) revert DataMarketErrors.AlreadyCompleted();
        if (block.timestamp <= transfer.startTime + TRANSFER_TIMEOUT) {
            revert DataMarketErrors.TransferTimeout(_transferId);
        }

        transfer.isCompleted = true;
        Purchase storage purchase = purchases[transfer.datasetId][
            transfer.receiver
        ];

        escrow.resolveDispute(purchase.escrowId, true);

        purchase.completed = false;
        purchase.disputed = false;

        emit TransferTimedOut(_transferId, transfer.datasetId);
    }

    function emergencyWithdraw(
        uint256 _datasetId
    ) external onlyOwner nonReentrant {
        Purchase storage purchase = purchases[_datasetId][msg.sender];
        if (purchase.escrowId == bytes32(0))
            revert DataMarketErrors.DatasetNotFound(_datasetId);
        if (block.timestamp <= purchase.timestamp + EMERGENCY_PERIOD) {
            revert DataMarketErrors.DisputePeriodNotEnded();
        }

        escrow.resolveDispute(purchase.escrowId, true);
        purchase.completed = false;
        purchase.disputed = false;

        emit EmergencyWithdrawal(_datasetId, msg.sender);
    }

    function getAllDatasets() external view returns (uint256[] memory) {
        uint256[] memory activeDatasets = new uint256[](datasetCount);
        uint256 activeCount = 0;

        for (uint256 i = 0; i < datasetCount; i++) {
            if (datasets[i].isActive) {
                activeDatasets[activeCount] = i;
                activeCount++;
            }
        }

        uint256[] memory result = new uint256[](activeCount);
        for (uint256 i = 0; i < activeCount; i++) {
            result[i] = activeDatasets[i];
        }

        return result;
    }

    function getDatasetDetails(
        uint256 _datasetId
    )
        external
        view
        returns (
            address seller,
            string memory metadataURI,
            string memory sampleDataURI,
            uint256 price,
            bool isActive,
            uint256 totalSales,
            uint256 validationScore
        )
    {
        Dataset storage dataset = datasets[_datasetId];

        return (
            dataset.seller,
            dataset.metadataURI,
            dataset.sampleDataURI,
            dataset.price,
            dataset.isActive,
            dataset.totalSales,
            dataset.validationScore
        );
    }

    function getDatasetsBySeller(
        address _seller
    ) external view returns (uint256[] memory) {
        return userDatasets[_seller];
    }

    function getPaginatedDatasets(
        uint256 _offset,
        uint256 _limit
    ) external view returns (uint256[] memory) {
        if (_offset >= datasetCount) revert DataMarketErrors.InvalidPaginationParams();

        uint256 remaining = datasetCount - _offset;
        uint256 count = remaining < _limit ? remaining : _limit;

        uint256[] memory result = new uint256[](count);
        uint256 resultIndex = 0;

        for (uint256 i = _offset; i < _offset + count; i++) {
            if (datasets[i].isActive) {
                result[resultIndex] = i;
                resultIndex++;
            }
        }

        return result;
    }

    function listDataset(
        string memory _metadataURI,
        string memory _sampleDataURI,
        uint256 _price,
        bytes memory _encryptedKey,
        string memory _dataType,
        uint256 _size,
        uint256 _sampleSize,
        bytes memory _formatProof,
        VerificationType _verificationType,
        bytes32 _zkVerificationKey,
        PrivacyLevel _privacyLevel,
        bytes memory _encryptedMetadata
    ) external whenNotPaused returns (uint256) {
        if (bytes(_metadataURI).length == 0) revert DataMarketErrors.InvalidMetadataURI();
        if (bytes(_sampleDataURI).length == 0) revert DataMarketErrors.InvalidSampleDataURI();
        if (_price == 0) revert DataMarketErrors.InvalidPrice();
        if (_size == 0) revert DataMarketErrors.InvalidDatasetSize();
        if (_sampleSize > _size) revert DataMarketErrors.InvalidSampleSize();
        if (_encryptedKey.length == 0) revert DataMarketErrors.InvalidEncryptedKey();

        uint256 datasetId = datasetCount++;

        bool isVerified = zkVerifier.verifyDataset(
            datasetId,
            _dataType,
            _size,
            true,
            _sampleSize,
            _formatProof,
            _verificationType
        );

        if (!isVerified) revert DataMarketErrors.VerificationFailed();

        if (_privacyLevel != PrivacyLevel.Public) {
            bytes32 txHash = keccak256(
                abi.encodePacked(datasetId, msg.sender, block.timestamp)
            );
            privacyManager.createPrivateTransaction(
                txHash,
                _encryptedMetadata,
                _zkVerificationKey,
                uint8(_privacyLevel)
            );
        }

        datasets[datasetId] = Dataset({
            seller: msg.sender,
            metadataURI: _metadataURI,
            sampleDataURI: _sampleDataURI,
            price: _price,
            isActive: true,
            totalSales: 0,
            validationScore: 0,
            encryptedKey: _encryptedKey,
            dataHash: keccak256(abi.encodePacked(_metadataURI, _size)),
            dataType: _dataType,
            size: _size,
            formatProof: _formatProof,
            verificationType: _verificationType,
            zkVerificationKey: _zkVerificationKey,
            transferId: bytes32(0),
            privacyLevel: _privacyLevel
        });

        userDatasets[msg.sender].push(datasetId);
        emit DatasetListed(datasetId, msg.sender, _price);
        return datasetId;
    }

    function purchaseDataset(
        uint256 _datasetId,
        bytes32 _zkProof
    ) external payable nonReentrant whenNotPaused {
        Dataset storage dataset = datasets[_datasetId];
        if (!dataset.isActive) revert DataMarketErrors.DatasetNotAvailable();
        if (msg.value < dataset.price) revert DataMarketErrors.InsufficientPayment();
        if (dataset.privacyLevel != PrivacyLevel.Public && !authorizedBuyers[_datasetId][msg.sender]) {
            revert DataMarketErrors.NotAuthorizedForPrivateDataset();
        }

        if (dataset.verificationType == VerificationType.ZKProof) {
            bool proofValid = zkVerifier.verifyZKProof(
                _datasetId,
                _zkProof,
                keccak256(abi.encodePacked(dataset.dataHash, msg.sender)),
                ProofType.Purchase
            );
            if (!proofValid) revert DataMarketErrors.ZKVerificationRequired();
        } else if (dataset.verificationType == VerificationType.Basic) {
            if (!verifyBasicIntegrity(dataset.dataHash)) revert DataMarketErrors.InvalidDataHash();
        }

        bytes32 transferId = transferProtocol.initiateTransfer(
            msg.sender,
            dataset.dataHash,
            dataset.encryptedKey,
            dataset.size
        );

        bytes32 escrowId = escrow.createEscrow{value: dataset.price}(
            payable(dataset.seller),
            string(abi.encodePacked("dataset-", _datasetId)),
            dataset.dataHash
        );

        purchases[_datasetId][msg.sender] = Purchase({
            buyer: msg.sender,
            timestamp: block.timestamp,
            completed: false,
            disputed: false,
            escrowId: escrowId,
            zkVerified: dataset.verificationType == VerificationType.ZKProof,
            accessProofHash: bytes32(0),
            consensusStatus: 0,
            zkProof: _zkProof,
            transferStatus: transferId,
            accessGranted: true
        });

        emit DatasetPurchased(_datasetId, msg.sender, escrowId);
    }

    function getTransferProgress(
        bytes32 _transferId
    )
        external
        view
        returns (uint256 confirmedChunks, uint256 totalChunks, bool isCompleted)
    {
        (
            uint256 _confirmedChunks,
            uint256 _totalChunks,
            bool _isCompleted,

        ) = transferProtocol.getTransferProgress(_transferId);
        return (_confirmedChunks, _totalChunks, _isCompleted);
    }

    function confirmChunkDelivery(
        uint256 _datasetId,
        uint256 _chunkIndex
    ) external nonReentrant whenNotPaused {
        Purchase storage purchase = purchases[_datasetId][msg.sender];
        if (purchase.completed) revert DataMarketErrors.AlreadyCompleted();

        transferProtocol.confirmChunk(purchase.transferStatus, _chunkIndex);

        (, , bool completed, ) = transferProtocol.getTransferProgress(
            purchase.transferStatus
        );

        if (completed) {
            purchase.completed = true;
            datasets[_datasetId].totalSales++;
            emit TransferCompleted(purchase.transferStatus, _datasetId);
        }
    }

    function initiateValidation(bytes32 _transferId) internal {
        consensusManager.initiateValidation(_transferId);
    }

    function getTransferDetails(
        bytes32 _transferId
    )
        external
        view
        returns (
            address sender,
            address receiver,
            uint256 startTime,
            bool isCompleted,
            bytes32 deliveryProof
        )
    {
        (
            address _sender,
            address _receiver,
            ,
            ,
            uint256 _startTime,
            ,
            bool _isCompleted,
            bytes32 _deliveryProof,
            ,

        ) = transferProtocol.getTransferDetails(_transferId);

        return (_sender, _receiver, _startTime, _isCompleted, _deliveryProof);
    }

    function getPrivacyDetails(
        bytes32 _txHash
    )
        external
        view
        returns (address creator, uint8 privacyLevel, bool isRevoked)
    {
        (creator, , privacyLevel, , isRevoked) = privacyManager
            .getTransactionMetadata(_txHash);
        return (creator, privacyLevel, isRevoked);
    }

    function verifyZKProof(
        uint256 _datasetId,
        bytes32 _proof
    ) public returns (bool) {
        Dataset storage dataset = datasets[_datasetId];
        Purchase storage purchase = purchases[_datasetId][msg.sender];

        if (purchase.escrowId == bytes32(0))
            revert DataMarketErrors.DatasetNotFound(_datasetId);
        if (purchase.zkVerified) revert DataMarketErrors.AlreadyCompleted();
        if (dataset.verificationType != VerificationType.ZKProof)
            revert DataMarketErrors.UnauthorizedAccess(msg.sender);

        bool isValid = zkVerifier.verifyZKProof(
            _datasetId,
            _proof,
            dataset.zkVerificationKey,
            ProofType.Purchase
        );

        if (isValid) {
            purchase.zkVerified = true;
            emit ZKProofVerified(_datasetId, msg.sender, true);
        }

        return isValid;
    }

    function updateDatasetMetadata(
        uint256 _datasetId,
        string memory _newMetadataURI
    ) external {
        Dataset storage dataset = datasets[_datasetId];
        if (msg.sender != dataset.seller)
            revert DataMarketErrors.UnauthorizedAccess(msg.sender);
        if (bytes(_newMetadataURI).length == 0)
            revert DataMarketErrors.InvalidAmount();

        dataset.metadataURI = _newMetadataURI;
        emit MetadataUpdated(_datasetId, _newMetadataURI);
    }

    function updatePrivacyLevel(
        uint256 _datasetId,
        PrivacyLevel _newLevel
    ) external {
        Dataset storage dataset = datasets[_datasetId];
        if (msg.sender != dataset.seller)
            revert DataMarketErrors.UnauthorizedAccess(msg.sender);
        if (_newLevel == PrivacyLevel.Private)
            revert DataMarketErrors.InvalidPrivacyLevel(uint8(_newLevel));

        bytes32 txHash = keccak256(
            abi.encodePacked(_datasetId, msg.sender, block.timestamp)
        );
        privacyManager.createPrivateTransaction(
            txHash,
            dataset.encryptedKey,
            dataset.zkVerificationKey,
            uint8(_newLevel)
        );

        dataset.privacyLevel = _newLevel;
        emit PrivacyLevelChanged(_datasetId, uint8(_newLevel));
    }

    function grantAccess(uint256 _datasetId, address _buyer) external {
        Dataset storage dataset = datasets[_datasetId];
        if (msg.sender != dataset.seller) revert DataMarketErrors.NotDatasetOwner();
        if (dataset.privacyLevel == PrivacyLevel.Public) revert DataMarketErrors.DatasetIsPublic();

        authorizedBuyers[_datasetId][_buyer] = true;
        emit AccessGranted(_datasetId, _buyer);
    }

    function revokeAccess(uint256 _datasetId, address _buyer) external {
        Dataset storage dataset = datasets[_datasetId];
        if (msg.sender != dataset.seller) revert DataMarketErrors.NotDatasetOwner();
        if (dataset.privacyLevel == PrivacyLevel.Public) revert DataMarketErrors.DatasetIsPublic();

        authorizedBuyers[_datasetId][_buyer] = false;
        emit AccessRevoked(_datasetId, _buyer);
    }

    function initiateTransfer(uint256 _datasetId) internal returns (bytes32) {
        bytes32 transferId = keccak256(
            abi.encodePacked(_datasetId, msg.sender, block.timestamp)
        );

        transfers[transferId] = Transfer({
            transferId: transferId,
            datasetId: _datasetId,
            sender: datasets[_datasetId].seller,
            receiver: msg.sender,
            startTime: block.timestamp,
            completedTime: 0,
            isCompleted: false
        });

        emit TransferInitiated(transferId, _datasetId);
        return transferId;
    }

    function confirmDelivery(
        uint256 _datasetId,
        bytes32 _deliveryHash
    ) external whenNotPaused {
        Purchase storage purchase = purchases[_datasetId][msg.sender];
        Dataset storage dataset = datasets[_datasetId];

        (, , bool consensusReached, bool approved, , ) = consensusManager
            .getValidationDetails(purchase.escrowId);

        if (!consensusReached) revert DataMarketErrors.ConsensusNotReached();
        if (!approved) revert DataMarketErrors.ConsensusRejected();
        if (purchase.escrowId == bytes32(0)) revert DataMarketErrors.DatasetNotFound(_datasetId);
        if (purchase.completed) revert DataMarketErrors.AlreadyCompleted();

        if (
            dataset.verificationType != VerificationType.ZKProof &&
            !purchase.zkVerified
        ) {
            revert DataMarketErrors.ZKVerificationRequired();
        }

        if (!transfers[purchase.transferStatus].isCompleted) {
            revert DataMarketErrors.TransferNotCompleted(
                purchase.transferStatus
            );
        }

        escrow.confirmDelivery(purchase.escrowId, _deliveryHash);
        escrow.releaseFunds(purchase.escrowId);

        purchase.completed = true;
        dataset.totalSales++;
    }

    function confirmDataTransfer(
        uint256 _datasetId,
        bytes32 _deliveryProof
    ) external nonReentrant whenNotPaused {
        Purchase storage purchase = purchases[_datasetId][msg.sender];
        if (purchase.completed) revert DataMarketErrors.AlreadyCompleted();

        transferProtocol.confirmTransfer(
            purchase.transferStatus,
            _deliveryProof
        );

        purchase.completed = true;
        datasets[_datasetId].totalSales++;

        emit TransferCompleted(purchase.transferStatus, _datasetId);
    }

    function updateDataset(
        uint256 _datasetId,
        uint256 _newPrice,
        bool _isActive
    ) external whenNotPaused {
        Dataset storage dataset = datasets[_datasetId];
        if (dataset.seller != msg.sender) revert DataMarketErrors.NotDatasetOwner();

        if (_newPrice > 0) {
            dataset.price = _newPrice;
        }
        dataset.isActive = _isActive;

        emit DatasetUpdated(_datasetId, dataset.price, dataset.isActive);
    }

    function raiseDispute(uint256 _datasetId) external whenNotPaused {
        Purchase storage purchase = purchases[_datasetId][msg.sender];
        if (purchase.escrowId == bytes32(0)) revert DataMarketErrors.PurchaseNotFound();
        if (purchase.disputed) revert DataMarketErrors.AlreadyDisputed();

        escrow.raiseDispute(purchase.escrowId);

        purchase.disputed = true;
        emit DisputeRaised(_datasetId, msg.sender);
    }

    function resolveDispute(
        uint256 _datasetId,
        address _buyer,
        bool _refundBuyer
    ) external onlyOwner whenNotPaused {
        Purchase storage purchase = purchases[_datasetId][_buyer];
        if (!purchase.disputed) revert DataMarketErrors.NoDisputeExists();

        escrow.resolveDispute(purchase.escrowId, _refundBuyer);

        if (_refundBuyer) {
            purchase.completed = false;
        } else {
            purchase.completed = true;
            datasets[_datasetId].totalSales++;
        }

        purchase.disputed = false;
        emit DisputeResolved(_datasetId, _buyer, _refundBuyer);
    }

    function updatePlatformFee(uint256 _newFee) external onlyOwner {
        if (_newFee > 1000) revert DataMarketErrors.InvalidPlatformFee();
        platformFee = _newFee;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function hasPurchased(
        uint256 _datasetId,
        address _user
    ) external view returns (bool) {
        return purchases[_datasetId][_user].completed;
    }
    function withdrawBalance() external onlyOwner {
        uint256 balance = address(this).balance;
        (bool success, ) = msg.sender.call{value: balance}("");
        if (!success) revert DataMarketErrors.TransferFailed();
    }

    function verifyBasicIntegrity(
        bytes32 _dataHash
    ) internal pure returns (bool) {
        return _dataHash != bytes32(0);
    }
}
