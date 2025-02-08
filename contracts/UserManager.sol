// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract UserManager is Ownable, Pausable, ReentrancyGuard {
    struct User {
        bool isRegistered;
        string profileURI;
        uint256 registerDate;
        uint256 reputation;
        bool isSeller;
        address[] authorizedDevices;
        uint256 salesCount;
        uint256 purchaseCount;
        mapping(bytes32 => bool) roles;
    }

    mapping(address => User) public users;
    mapping(string => address) public usernameToAddress;
    mapping(address => bool) public authorizedContracts;

    event UserRegistered(address indexed user, string profileURI);
    event SellerRegistered(address indexed seller);
    event ReputationUpdated(address indexed user, uint256 newScore);
    event ContractAuthorized(address indexed contractAddress);
    event ContractDeauthorized(address indexed contractAddress);

    constructor() Ownable(msg.sender) {}

    function authorizeContract(address _contract) external onlyOwner {
        authorizedContracts[_contract] = true;
        emit ContractAuthorized(_contract);
    }

    function deauthorizeContract(address _contract) external onlyOwner {
        authorizedContracts[_contract] = false;
        emit ContractDeauthorized(_contract);
    }

    function registerUser(
        string memory _profileURI,
        string memory _username
    ) external nonReentrant whenNotPaused {
        require(!users[msg.sender].isRegistered, "Already registered");
        require(usernameToAddress[_username] == address(0), "Username taken");
        require(bytes(_profileURI).length > 0, "Invalid profile URI");
        require(bytes(_username).length > 0, "Invalid username");

        User storage newUser = users[msg.sender];
        newUser.isRegistered = true;
        newUser.profileURI = _profileURI;
        newUser.registerDate = block.timestamp;
        newUser.reputation = 0;
        
        usernameToAddress[_username] = msg.sender;
        
        emit UserRegistered(msg.sender, _profileURI);
    }

    function registerAsSeller(
        address[] memory _paymentAddresses,
        string memory _sellerMetadata
    ) external nonReentrant whenNotPaused {
        require(users[msg.sender].isRegistered, "Not registered");
        require(!users[msg.sender].isSeller, "Already a seller");
        require(bytes(_sellerMetadata).length > 0, "Invalid metadata");
        require(_paymentAddresses.length > 0, "No payment addresses");

        User storage user = users[msg.sender];
        user.isSeller = true;
        user.authorizedDevices = _paymentAddresses;

        emit SellerRegistered(msg.sender);
    }

    function updateReputation(address _user, uint256 _score) external {
        require(authorizedContracts[msg.sender], "Unauthorized");
        require(users[_user].isRegistered, "User not registered");
        require(_score <= 100, "Invalid score");

        users[_user].reputation = _score;
        emit ReputationUpdated(_user, _score);
    }

    function getUserDetails(address _user) external view returns (
        bool isRegistered,
        string memory profileURI,
        uint256 registerDate,
        uint256 reputation,
        bool isSeller,
        uint256 salesCount,
        uint256 purchaseCount
    ) {
        User storage user = users[_user];
        return (
            user.isRegistered,
            user.profileURI,
            user.registerDate,
            user.reputation,
            user.isSeller,
            user.salesCount,
            user.purchaseCount
        );
    }

    function getAuthorizedDevices(address _user) external view returns (address[] memory) {
        return users[_user].authorizedDevices;
    }

    function updateUserSalesCount(address _user) external {
        require(authorizedContracts[msg.sender], "Unauthorized");
        users[_user].salesCount++;
    }

    function updateUserPurchaseCount(address _user) external {
        require(authorizedContracts[msg.sender], "Unauthorized");
        users[_user].purchaseCount++;
    }

    function checkIsRegistered(address _user) external view returns (bool) {
        return users[_user].isRegistered;
    }

    function checkIsSeller(address _user) external view returns (bool) {
        return users[_user].isSeller;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}