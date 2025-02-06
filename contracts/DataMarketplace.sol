// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./DataEscrow.sol";
import "./IDataVerifier.sol";

contract DataMarketplace is ReentrancyGuard, Ownable, Pausable {
    DataEscrow public escrow;
    IDataVerifier public verifier;

    struct Dataset {
        address seller;
        string metadataURI;
        string sampleDataURI;
        uint256 price;
        bool isActive;
        uint256 totalSales;
        uint256 validationScore;
        bytes encryptedKey;
        bytes32 dataHash;
        string dataType;
        uint256 size;
        bytes formatProof;
        bool requiresVerification;
    }

    struct Purchase {
        address buyer;
        uint256 timestamp;
        bool completed;
        bool disputed;
        bytes32 escrowId;
        bool zkVerified;
        bytes32 accessProofHash;
        uint8 consensusStatus;
    }

    mapping(uint256 => Dataset) public datasets;
    mapping(uint256 => mapping(address => Purchase)) public purchases;
    mapping(address => uint256[]) public userDatasets;
    mapping(bytes32 => uint256) public escrowToDataset;
    uint256 public datasetCount;
    uint256 public platformFee;

    event DatasetListed(uint256 indexed datasetId, address indexed seller, uint256 price);
    event DatasetPurchased(uint256 indexed datasetId, address indexed buyer, bytes32 escrowId);
    event DatasetUpdated(uint256 indexed datasetId, uint256 newPrice, bool isActive);
    event DisputeRaised(uint256 indexed datasetId, address indexed buyer);
    event DisputeResolved(uint256 indexed datasetId, address indexed buyer, bool buyerRefunded);
    event EscrowAddressUpdated(address newEscrow);
    event ProofVerified(uint256 indexed datasetId, bytes32 proofHash, bool success);
    event ConsensusValidated(uint256 indexed datasetId, bytes32 indexed escrowId, bool approved);
    event VerifierUpdated(address newVerifier);

    constructor(
        uint256 _platformFee,
        address _escrowAddress,
        address _verifierAddress
    ) Ownable(msg.sender) {
        platformFee = _platformFee;
        escrow = DataEscrow(_escrowAddress);
        verifier = IDataVerifier(_verifierAddress);
    }

    function setVerifier(address _newVerifier) external onlyOwner {
        require(_newVerifier != address(0), "Invalid address");
        verifier = IDataVerifier(_newVerifier);
        emit VerifierUpdated(_newVerifier);
    }

    function updateEscrowAddress(address _newEscrow) external onlyOwner {
        require(_newEscrow != address(0), "Invalid address");
        escrow = DataEscrow(_newEscrow);
        emit EscrowAddressUpdated(_newEscrow);
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
        require(_offset < datasetCount, "Offset out of bounds");

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
        bool _requiresVerification
    ) external whenNotPaused returns (uint256) {
        require(bytes(_metadataURI).length > 0, "Metadata URI required");
        require(bytes(_sampleDataURI).length > 0, "Sample data URI required");
        require(_price > 0, "Price must be greater than 0");

        uint256 datasetId = datasetCount++;

        bool isVerified = verifier.verifyDataset(
            datasetId,
            _dataType,
            _size,
            true,
            _sampleSize,
            _formatProof
        );
        require(isVerified, "Dataset verification failed");

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
            requiresVerification: _requiresVerification
        });

        userDatasets[msg.sender].push(datasetId);
        emit DatasetListed(datasetId, msg.sender, _price);
        return datasetId;
    }

    function submitProof(
        uint256 _datasetId,
        bytes calldata _proof
    ) external whenNotPaused {
        Dataset storage dataset = datasets[_datasetId];
        Purchase storage purchase = purchases[_datasetId][msg.sender];

        require(purchase.escrowId != bytes32(0), "No purchase found");
        require(!purchase.zkVerified, "Already verified");
        require(dataset.requiresVerification, "Verification not required");

        bool isValid = verifier.verifyDataset(
            _datasetId,
            dataset.dataType,
            dataset.size,
            true,
            dataset.size * 5 / 100,
            _proof
        );
        require(isValid, "Proof verification failed");

        purchase.zkVerified = true;
        bytes32 proofHash = keccak256(_proof);
        emit ProofVerified(_datasetId, proofHash, true);
    }

    function purchaseDataset(
        uint256 _datasetId,
        bytes calldata _accessProof
    ) external payable nonReentrant whenNotPaused {
        Dataset storage dataset = datasets[_datasetId];
        require(dataset.isActive, "Dataset not available");
        require(msg.value >= dataset.price, "Insufficient payment");
        require(dataset.seller != msg.sender, "Cannot buy own dataset");
        require(
            !purchases[_datasetId][msg.sender].completed,
            "Already purchased"
        );

        bytes32 escrowId = escrow.createEscrow{value: dataset.price}(
            payable(dataset.seller),
            string(abi.encodePacked("dataset-", _datasetId))
        );

        purchases[_datasetId][msg.sender] = Purchase({
            buyer: msg.sender,
            timestamp: block.timestamp,
            completed: false,
            disputed: false,
            escrowId: escrowId,
            zkVerified: false,
            accessProofHash: keccak256(_accessProof),
            consensusStatus: 0
        });

        if (msg.value > dataset.price) {
            (bool refundSuccess, ) = msg.sender.call{
                value: msg.value - dataset.price
            }("");
            require(refundSuccess, "Failed to refund excess");
        }

        emit DatasetPurchased(_datasetId, msg.sender, escrowId);
    }

    function confirmDelivery(
        uint256 _datasetId,
        bytes32 _deliveryHash
    ) external whenNotPaused {
        Purchase storage purchase = purchases[_datasetId][msg.sender];
        Dataset storage dataset = datasets[_datasetId];

        require(purchase.escrowId != bytes32(0), "No escrow found");
        require(!purchase.completed, "Already completed");

        escrow.confirmDelivery(purchase.escrowId, _deliveryHash);
        escrow.releaseFunds(purchase.escrowId);

        purchase.completed = true;
        purchase.consensusStatus = 1;
        dataset.totalSales++;

        emit ConsensusValidated(_datasetId, purchase.escrowId, true);
    }

    function updateDataset(
        uint256 _datasetId,
        uint256 _newPrice,
        bool _isActive
    ) external whenNotPaused {
        Dataset storage dataset = datasets[_datasetId];
        require(dataset.seller == msg.sender, "Not dataset owner");

        if (_newPrice > 0) {
            dataset.price = _newPrice;
        }
        dataset.isActive = _isActive;

        emit DatasetUpdated(_datasetId, dataset.price, dataset.isActive);
    }

    function raiseDispute(uint256 _datasetId) external whenNotPaused {
        Purchase storage purchase = purchases[_datasetId][msg.sender];
        require(purchase.escrowId != bytes32(0), "No purchase found");
        require(!purchase.disputed, "Already disputed");

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
        require(purchase.disputed, "No dispute exists");

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
        require(_newFee <= 1000, "Fee cannot exceed 100%");
        platformFee = _newFee;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function getUserDatasets(
        address _user
    ) external view returns (uint256[] memory) {
        return userDatasets[_user];
    }

    function hasPurchased(
        uint256 _datasetId,
        address _user
    ) external view returns (bool) {
        return purchases[_datasetId][_user].completed;
    }
}
