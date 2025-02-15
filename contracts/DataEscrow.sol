// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./UserManager.sol";
import "../lib/DataMarketInterface.sol";
import "../lib/DataMarketErrors.sol";

contract DataEscrow is IDataEscrow, ReentrancyGuard, Ownable, Pausable {
    using DataMarketErrors for *;

    UserManager public userManager;
    IDataMarketplace public marketplace;
    IConsensusValidator public consensusValidator;
    struct EscrowTransaction {
        address payable buyer;
        address payable seller;
        uint256 amount;
        uint256 createdAt;
        uint256 completedAt;
        bool isReleased;
        bool isRefunded;
        bool isDisputed;
        string datasetId;
        bytes32 deliveryHash;
        bytes32 zkProofHash;
        uint8 consensusStatus;
        bytes32 encryptionProof;
        bytes32 dataHash;
        bytes32 privacyProof;
        uint8 encryptionLevel;
        bytes encryptedMetadata;
        uint256 validatorCount;
        uint256 approvalCount;
        uint256 rejectionCount;
        mapping(address => bool) validators;
    }

    mapping(bytes32 => EscrowTransaction) public transactions;
    mapping(address => bytes32[]) public userTransactions;
    mapping(bytes32 => address[]) public transactionValidators;
    mapping(address => bool) public registeredValidators;

    uint256 public constant DISPUTE_PERIOD = 3 days;
    uint256 public constant AUTO_RELEASE_PERIOD = 7 days;
    uint256 public minValidators;
    uint256 public consensusThreshold;
    uint256 public platformFee;

    event EscrowCreated(bytes32 indexed transactionId, address indexed buyer, address indexed seller, uint256 amount, string datasetId);
    event FundsReleased(bytes32 indexed transactionId);
    event FundsRefunded(bytes32 indexed transactionId);
    event DisputeRaised(bytes32 indexed transactionId);
    event DisputeResolved(bytes32 indexed transactionId, bool buyerRefunded);
    event DeliveryConfirmed(bytes32 indexed transactionId, bytes32 deliveryHash);
    event ConsensusRequired(bytes32 indexed transactionId);
    event ValidatorAssigned(bytes32 indexed transactionId, address indexed validator);
    event ProofSubmitted(bytes32 indexed transactionId, bytes32 proofHash);
    event ConsensusReached(bytes32 indexed transactionId, bool approved);

    constructor(uint256 _platformFee, address _userManagerAddress) Ownable(msg.sender) {
        if (_platformFee > 1000) revert DataMarketErrors.InvalidFee();
        platformFee = _platformFee;
        userManager = UserManager(_userManagerAddress);
    }


    function createEscrow(
        address payable _seller,
        string memory _datasetId,
        bytes32 _dataHash
    ) external payable override nonReentrant whenNotPaused returns (bytes32) {
        if (!userManager.checkIsRegistered(msg.sender)) revert DataMarketErrors.NotRegistered();
        if (!userManager.checkIsSeller(_seller)) revert DataMarketErrors.NotSeller();
        if (!marketplace.isDatasetListed(_datasetId)) revert DataMarketErrors.DatasetNotFound(0);
        if (msg.value == 0) revert DataMarketErrors.InvalidAmount();
        if (_seller == address(0)) revert DataMarketErrors.InvalidAddress();
        if (_seller == msg.sender) revert DataMarketErrors.InvalidAccess();

        bytes32 transactionId = keccak256(
            abi.encodePacked(
                msg.sender,
                _seller,
                _datasetId,
                block.timestamp,
                _dataHash
            )
        );

        if (transactions[transactionId].amount != 0) revert DataMarketErrors.EscrowAlreadyExists();

        EscrowTransaction storage transaction = transactions[transactionId];

        transaction.buyer = payable(msg.sender);
        transaction.seller = _seller;
        transaction.amount = msg.value;
        transaction.createdAt = block.timestamp;
        transaction.completedAt = 0;
        transaction.isReleased = false;
        transaction.isRefunded = false;
        transaction.isDisputed = false;
        transaction.datasetId = _datasetId;
        transaction.deliveryHash = bytes32(0);
        transaction.zkProofHash = bytes32(0);
        transaction.consensusStatus = 0;
        transaction.encryptionProof = bytes32(0);
        transaction.dataHash = _dataHash;
        transaction.privacyProof = bytes32(0);
        transaction.encryptionLevel = 0;
        transaction.encryptedMetadata = "";
        transaction.validatorCount = consensusValidator.getValidatorCount();
        transaction.approvalCount = 0;
        transaction.rejectionCount = 0;

        userTransactions[msg.sender].push(transactionId);
        userTransactions[_seller].push(transactionId);

        emit EscrowCreated(
            transactionId,
            msg.sender,
            _seller,
            msg.value,
            _datasetId
        );

        return transactionId;
    }

    function confirmDelivery(
        bytes32 _transactionId,
        bytes32 _deliveryHash
    ) external override nonReentrant whenNotPaused {
        EscrowTransaction storage transaction = transactions[_transactionId];
        if (msg.sender != transaction.buyer) revert DataMarketErrors.UnauthorizedAccess(msg.sender);
        if (transaction.isReleased) revert DataMarketErrors.FundsAlreadyReleased();
        if (transaction.isRefunded) revert DataMarketErrors.FundsAlreadyRefunded();

        if (!marketplace.verifyDataIntegrity(
            _deliveryHash,
            transaction.dataHash
        )) revert DataMarketErrors.InvalidProof();

        transaction.deliveryHash = _deliveryHash;
        transaction.completedAt = block.timestamp;

        emit DeliveryConfirmed(_transactionId, _deliveryHash);
    }

    function raiseDispute(
        bytes32 _transactionId
    ) external override nonReentrant whenNotPaused {
        EscrowTransaction storage transaction = transactions[_transactionId];
        if (msg.sender != transaction.buyer) revert DataMarketErrors.UnauthorizedAccess(msg.sender);
        if (transaction.isReleased) revert DataMarketErrors.FundsAlreadyReleased();
        if (transaction.isRefunded) revert DataMarketErrors.FundsAlreadyRefunded();
        if (block.timestamp > transaction.createdAt + DISPUTE_PERIOD) revert DataMarketErrors.DisputePeriodExpired();

        transaction.isDisputed = true;
        emit DisputeRaised(_transactionId);
    }

    function resolveDispute(
        bytes32 _transactionId,
        bool _refundBuyer
    ) external override onlyOwner nonReentrant whenNotPaused {
        EscrowTransaction storage transaction = transactions[_transactionId];
        if (!transaction.isDisputed) revert DataMarketErrors.NoDisputeExists();
        if (transaction.isReleased) revert DataMarketErrors.FundsAlreadyReleased();
        if (transaction.isRefunded) revert DataMarketErrors.FundsAlreadyRefunded();

        if (_refundBuyer) {
            transaction.isRefunded = true;
            (bool success, ) = transaction.buyer.call{value: transaction.amount}("");
            if (!success) revert DataMarketErrors.TransferFailed();
            emit FundsRefunded(_transactionId);
        } else {
            transaction.isReleased = true;
            (bool success, ) = transaction.seller.call{value: transaction.amount}("");
            if (!success) revert DataMarketErrors.TransferFailed();
            emit FundsReleased(_transactionId);
        }

        emit DisputeResolved(_transactionId, _refundBuyer);
    }

    function releaseFunds(
        bytes32 _transactionId
    ) external override nonReentrant whenNotPaused {
        EscrowTransaction storage transaction = transactions[_transactionId];
        if (msg.sender != transaction.buyer && 
            msg.sender != owner() &&
            block.timestamp < transaction.createdAt + AUTO_RELEASE_PERIOD) {
            revert DataMarketErrors.UnauthorizedAccess(msg.sender);
        }
        if (transaction.isReleased) revert DataMarketErrors.FundsAlreadyReleased();
        if (transaction.isRefunded) revert DataMarketErrors.FundsAlreadyRefunded();
        if (transaction.isDisputed) revert DataMarketErrors.DisputeAlreadyRaised();
        if (transaction.consensusStatus != 1) revert DataMarketErrors.ConsensusNotReached();

        transaction.isReleased = true;
        transaction.completedAt = block.timestamp;

        uint256 feeAmount = (transaction.amount * platformFee) / 10000;
        uint256 sellerAmount = transaction.amount - feeAmount;

        (bool feeSuccess, ) = owner().call{value: feeAmount}("");
        if (!feeSuccess) revert DataMarketErrors.FeeTransferFailed();

        (bool success, ) = transaction.seller.call{value: sellerAmount}("");
        if (!success) revert DataMarketErrors.TransferFailed();

        emit FundsReleased(_transactionId);
    }

    function registerValidator(address _validator) external onlyOwner {
        if (_validator == address(0)) revert DataMarketErrors.InvalidAddress();
        registeredValidators[_validator] = true;
    }

    function isValidator(address _validator) public view returns (bool) {
        return registeredValidators[_validator];
    }

    function hasConsensus(bytes32 _transactionId) public view returns (bool) {
        EscrowTransaction storage txn = transactions[_transactionId];
        uint256 totalVotes = txn.approvalCount + txn.rejectionCount;
        uint256 requiredVotes = (txn.validatorCount * consensusThreshold) / 100;
        return totalVotes >= requiredVotes;
    }

    function setMarketplace(address _marketplace) external onlyOwner {
        if (_marketplace == address(0)) revert DataMarketErrors.InvalidMarketplace();
        marketplace = IDataMarketplace(_marketplace);
    }

    function setConsensusValidator(address _validator) external onlyOwner {
        if (_validator == address(0)) revert DataMarketErrors.InvalidConsensusValidator();
        consensusValidator = IConsensusValidator(_validator);
    }

    function submitZKProof(
        bytes32 _transactionId,
        bytes32 _proofHash
    ) external nonReentrant whenNotPaused {
        EscrowTransaction storage transaction = transactions[_transactionId];
        if (msg.sender != transaction.buyer) revert DataMarketErrors.UnauthorizedAccess(msg.sender);
        if (transaction.isReleased) revert DataMarketErrors.FundsAlreadyReleased();

        transaction.zkProofHash = _proofHash;
        emit ProofSubmitted(_transactionId, _proofHash);
    }

    function getUserTransactions(
        address _user
    ) external view returns (bytes32[] memory) {
        return userTransactions[_user];
    }

    function getEscrowState(bytes32 _escrowId) external view override returns (
        bool exists,
        bool released,
        bool disputed
    ) {
        EscrowTransaction storage txn = transactions[_escrowId];
        return (
            txn.amount > 0,
            txn.isReleased,
            txn.isDisputed
        );
    }

    function updatePlatformFee(uint256 _newFee) external onlyOwner {
        if (_newFee > 1000) revert DataMarketErrors.InvalidFee();
        platformFee = _newFee;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function withdrawStuckTokens(IERC20 _token) external onlyOwner {
        uint256 balance = _token.balanceOf(address(this));
        if (balance == 0) revert DataMarketErrors.NoTokensToWithdraw();
        if (!_token.transfer(owner(), balance)) revert DataMarketErrors.TransferFailed();
    }
}
