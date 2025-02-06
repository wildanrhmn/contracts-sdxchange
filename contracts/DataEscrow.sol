// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DataEscrow is ReentrancyGuard, Ownable, Pausable {
    uint256 public constant DISPUTE_PERIOD = 3 days;
    uint256 public constant AUTO_RELEASE_PERIOD = 7 days;

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
        bytes32 zkProofHash;        // Added for ZK proof reference
        uint8 consensusStatus;      // Added for consensus tracking
        bytes32 encryptionProof;    // Added for privacy verification
    }

    mapping(bytes32 => EscrowTransaction) public transactions;
    mapping(address => bytes32[]) public userTransactions;
    mapping(bytes32 => address[]) public transactionValidators;
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
    event DeliveryConfirmed(bytes32 indexed transactionId, bytes32 deliveryHash);
    event ConsensusRequired(bytes32 indexed transactionId);
    event ValidatorAssigned(bytes32 indexed transactionId, address indexed validator);
    event ProofSubmitted(bytes32 indexed transactionId, bytes32 proofHash);
    event ConsensusReached(bytes32 indexed transactionId, bool approved);

    constructor(uint256 _platformFee) Ownable(msg.sender) {
        require(_platformFee <= 1000, "Fee cannot exceed 10%");
        platformFee = _platformFee;
    }

    function createEscrow(
        address payable _seller,
        string memory _datasetId
    ) external payable nonReentrant whenNotPaused returns (bytes32) {
        require(msg.value > 0, "Amount must be greater than 0");
        require(_seller != address(0), "Invalid seller address");
        require(_seller != msg.sender, "Cannot escrow to self");

        bytes32 transactionId = keccak256(
            abi.encodePacked(
                msg.sender,
                _seller,
                _datasetId,
                block.timestamp
            )
        );

        require(transactions[transactionId].amount == 0, "Transaction exists");

        transactions[transactionId] = EscrowTransaction({
            buyer: payable(msg.sender),
            seller: _seller,
            amount: msg.value,
            createdAt: block.timestamp,
            completedAt: 0,
            isReleased: false,
            isRefunded: false,
            isDisputed: false,
            datasetId: _datasetId,
            deliveryHash: bytes32(0),
            zkProofHash: bytes32(0),
            consensusStatus: 0,
            encryptionProof: bytes32(0)
        });

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

        transactionValidators[_transactionId].push(msg.sender);
        
        if (hasConsensus(_transactionId)) {
            transaction.consensusStatus = _approved ? 1 : 2;
            emit ConsensusReached(_transactionId, _approved);
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
            (bool success, ) = transaction.buyer.call{value: transaction.amount}("");
            require(success, "Refund failed");
            emit FundsRefunded(_transactionId);
        } else {
            transaction.isReleased = true;
            (bool success, ) = transaction.seller.call{value: transaction.amount}("");
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

    function isValidator(address _validator) internal pure returns (bool) {
        return true;
    }

    function hasConsensus(bytes32 _transactionId) internal view returns (bool) {
        return transactionValidators[_transactionId].length >= 3;
    }
}
