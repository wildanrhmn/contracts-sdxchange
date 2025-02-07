// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../lib/DataMarketInterface.sol";

contract DataEscrow is ReentrancyGuard, Ownable, Pausable {
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

    event EscrowCreated(
        bytes32 indexed transactionId,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        string datasetId
    );
    event FundsReleased(bytes32 indexed transactionId);
    event FundsRefunded(bytes32 indexed transactionId);
    event DisputeRaised(bytes32 indexed transactionId);
    event DisputeResolved(bytes32 indexed transactionId, bool buyerRefunded);
    event DeliveryConfirmed(
        bytes32 indexed transactionId,
        bytes32 deliveryHash
    );
    event ConsensusRequired(bytes32 indexed transactionId);
    event ValidatorAssigned(
        bytes32 indexed transactionId,
        address indexed validator
    );
    event ProofSubmitted(bytes32 indexed transactionId, bytes32 proofHash);
    event ConsensusReached(bytes32 indexed transactionId, bool approved);

    constructor(uint256 _platformFee) Ownable(msg.sender) {
        require(_platformFee <= 1000, "Fee cannot exceed 10%");
        platformFee = _platformFee;
    }

    function registerValidator(address _validator) external onlyOwner {
        require(_validator != address(0), "Invalid validator");
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
        require(_marketplace != address(0), "Invalid address");
        marketplace = IDataMarketplace(_marketplace);
    }

    function setConsensusValidator(address _validator) external onlyOwner {
        require(_validator != address(0), "Invalid address");
        consensusValidator = IConsensusValidator(_validator);
    }

    function createEscrow(
        address payable _seller,
        string memory _datasetId,
        bytes32 _dataHash
    ) external payable nonReentrant whenNotPaused returns (bytes32) {
        require(marketplace.isDatasetListed(_datasetId), "Dataset not listed");
        require(msg.value > 0, "Amount must be greater than 0");
        require(_seller != address(0), "Invalid seller address");
        require(_seller != msg.sender, "Cannot escrow to self");

        bytes32 transactionId = keccak256(
            abi.encodePacked(
                msg.sender,
                _seller,
                _datasetId,
                block.timestamp,
                _dataHash
            )
        );

        require(transactions[transactionId].amount == 0, "Transaction exists");

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
    ) external nonReentrant whenNotPaused {
        EscrowTransaction storage transaction = transactions[_transactionId];
        require(msg.sender == transaction.buyer, "Only buyer can confirm");
        require(!transaction.isReleased, "Already released");
        require(!transaction.isRefunded, "Already refunded");

        require(
            marketplace.verifyDataIntegrity(
                _deliveryHash,
                transaction.dataHash
            ),
            "Data integrity check failed"
        );

        transaction.deliveryHash = _deliveryHash;
        transaction.completedAt = block.timestamp;

        emit DeliveryConfirmed(_transactionId, _deliveryHash);
    }

    function releaseFunds(
        bytes32 _transactionId
    ) external nonReentrant whenNotPaused {
        EscrowTransaction storage transaction = transactions[_transactionId];
        require(
            msg.sender == transaction.buyer ||
                msg.sender == owner() ||
                block.timestamp >= transaction.createdAt + AUTO_RELEASE_PERIOD,
            "Not authorized"
        );
        require(!transaction.isReleased, "Already released");
        require(!transaction.isRefunded, "Already refunded");
        require(!transaction.isDisputed, "Transaction disputed");
        require(transaction.consensusStatus == 1, "Consensus not reached");

        transaction.isReleased = true;
        transaction.completedAt = block.timestamp;

        uint256 feeAmount = (transaction.amount * platformFee) / 10000;
        uint256 sellerAmount = transaction.amount - feeAmount;

        (bool feeSuccess, ) = owner().call{value: feeAmount}("");
        require(feeSuccess, "Fee transfer failed");

        (bool success, ) = transaction.seller.call{value: sellerAmount}("");
        require(success, "Transfer to seller failed");

        emit FundsReleased(_transactionId);
    }

    function submitZKProof(
        bytes32 _transactionId,
        bytes32 _proofHash
    ) external nonReentrant whenNotPaused {
        EscrowTransaction storage transaction = transactions[_transactionId];
        require(msg.sender == transaction.buyer, "Only buyer can submit");
        require(!transaction.isReleased, "Already released");

        transaction.zkProofHash = _proofHash;
        emit ProofSubmitted(_transactionId, _proofHash);
    }

    function validateTransaction(
        bytes32 _transactionId,
        bool _approved
    ) external nonReentrant whenNotPaused {
        EscrowTransaction storage transaction = transactions[_transactionId];
        require(isValidator(msg.sender), "Not a validator");
        require(!transaction.isReleased, "Already released");
        require(!transaction.validators[msg.sender], "Already validated");

        transaction.validators[msg.sender] = true;

        if (_approved) {
            transaction.approvalCount++;
        } else {
            transaction.rejectionCount++;
        }

        if (hasConsensus(_transactionId)) {
            bool consensusApproved = transaction.approvalCount >
                transaction.rejectionCount;
            transaction.consensusStatus = consensusApproved ? 1 : 2;
            emit ConsensusReached(_transactionId, consensusApproved);
        }
    }

    function raiseDispute(
        bytes32 _transactionId
    ) external nonReentrant whenNotPaused {
        EscrowTransaction storage transaction = transactions[_transactionId];
        require(msg.sender == transaction.buyer, "Only buyer can dispute");
        require(!transaction.isReleased, "Already released");
        require(!transaction.isRefunded, "Already refunded");
        require(
            block.timestamp <= transaction.createdAt + DISPUTE_PERIOD,
            "Dispute period ended"
        );

        transaction.isDisputed = true;
        emit DisputeRaised(_transactionId);
    }

    function resolveDispute(
        bytes32 _transactionId,
        bool _refundBuyer
    ) external onlyOwner nonReentrant whenNotPaused {
        EscrowTransaction storage transaction = transactions[_transactionId];
        require(transaction.isDisputed, "No dispute exists");
        require(!transaction.isReleased, "Already released");
        require(!transaction.isRefunded, "Already refunded");

        if (_refundBuyer) {
            transaction.isRefunded = true;
            (bool success, ) = transaction.buyer.call{
                value: transaction.amount
            }("");
            require(success, "Refund failed");
            emit FundsRefunded(_transactionId);
        } else {
            transaction.isReleased = true;
            (bool success, ) = transaction.seller.call{
                value: transaction.amount
            }("");
            require(success, "Release failed");
            emit FundsReleased(_transactionId);
        }

        emit DisputeResolved(_transactionId, _refundBuyer);
    }

    function getUserTransactions(
        address _user
    ) external view returns (bytes32[] memory) {
        return userTransactions[_user];
    }

    function updatePlatformFee(uint256 _newFee) external onlyOwner {
        require(_newFee <= 1000, "Fee cannot exceed 10%");
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
        require(balance > 0, "No tokens to withdraw");
        require(_token.transfer(owner(), balance), "Transfer failed");
    }
}
