// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../lib/DataMarketInterface.sol";

contract UserManager is IUserManager, Ownable, Pausable, ReentrancyGuard {

    struct User {
        string profileURI;
        uint256 registerDate;
        bool isRegistered;
        UserRole role;
    }

    struct Validator {
        uint256 stakedAmount;
        uint256 validationsCount;
        uint256 successfulValidations;
        bool isActive;
    }

    uint256 public validatorCount;
    uint256 public minValidators = 3;
    uint256 public constant MINIMUM_STAKE = 0.0001 ether;
    
    mapping(address => User) public users;
    mapping(address => Validator) public validators;
    mapping(uint256 => address) private validatorAddresses;
    uint256 private currentValidatorIndex;

    IConsensusValidator public consensusValidator;

    event UserRegistered(address indexed user, string profileURI, UserRole role);
    event ValidatorRegistered(address indexed validator, uint256 stake);
    event ValidatorStakeIncreased(address indexed validator, uint256 newStake);
    event ValidatorStatsUpdated(address indexed validator, uint256 totalValidations, uint256 successfulValidations);
    event ValidatorDeactivated(address indexed validator);

    constructor(address _consensusValidator) Ownable(msg.sender) {
        consensusValidator = IConsensusValidator(_consensusValidator);
    }

    function setConsensusValidator(address _consensusValidator) external onlyOwner {
        consensusValidator = IConsensusValidator(_consensusValidator);
    }

    function registerUser(
        string memory _profileURI,
        UserRole _role
    ) external payable nonReentrant whenNotPaused {
        require(!users[msg.sender].isRegistered, "Already registered");
        require(bytes(_profileURI).length > 0, "Invalid profile URI");

        // If registering as validator, check stake
        if (_role == UserRole.Validator) {
            require(msg.value >= MINIMUM_STAKE, "Insufficient stake");
            
            validators[msg.sender] = Validator({
                stakedAmount: msg.value,
                validationsCount: 0,
                successfulValidations: 0,
                isActive: true
            });

            validatorAddresses[currentValidatorIndex] = msg.sender;
            currentValidatorIndex++;
            validatorCount++;
        } else {
            require(msg.value == 0, "Only validators need stake");
        }

        users[msg.sender] = User({
            profileURI: _profileURI,
            registerDate: block.timestamp,
            isRegistered: true,
            role: _role
        });

        emit UserRegistered(msg.sender, _profileURI, _role);
        if (_role == UserRole.Validator) {
            emit ValidatorRegistered(msg.sender, msg.value);
        }
    }

    function getUserDetails(address _user) external view returns (
        bool isRegistered,
        string memory profileURI,
        uint256 registerDate,
        UserRole role,
        // Additional validator details if applicable
        bool isValidator,
        uint256 stakedAmount,
        bool isActive,
        uint256 validationsCount,
        uint256 successfulValidations
    ) {
        User storage user = users[_user];
        Validator storage validator = validators[_user];
        
        return (
            user.isRegistered,
            user.profileURI,
            user.registerDate,
            user.role,
            user.role == UserRole.Validator,
            validator.stakedAmount,
            validator.isActive,
            validator.validationsCount,
            validator.successfulValidations
        );
    }

    function increaseValidatorStake() external payable whenNotPaused {
        require(users[msg.sender].role == UserRole.Validator, "Not a validator");
        require(validators[msg.sender].isActive, "Validator not active");

        validators[msg.sender].stakedAmount += msg.value;
        emit ValidatorStakeIncreased(msg.sender, validators[msg.sender].stakedAmount);
    }

    function withdrawValidatorStake() external nonReentrant whenNotPaused {
        require(users[msg.sender].role == UserRole.Validator, "Not a validator");
        require(validators[msg.sender].isActive, "Validator not active");
        require(block.timestamp >= users[msg.sender].registerDate + 30 days, "Withdrawal locked");

        uint256 stakeToReturn = validators[msg.sender].stakedAmount;
        validators[msg.sender].stakedAmount = 0;
        validators[msg.sender].isActive = false;
        validatorCount--;

        payable(msg.sender).transfer(stakeToReturn);
        emit ValidatorDeactivated(msg.sender);
    }

    function getAllActiveValidators() external view override returns (address[] memory) {
        address[] memory activeValidators = new address[](validatorCount);
        uint256 activeCount = 0;
        
        for(uint256 i = 0; i < currentValidatorIndex; i++) {
            address validatorAddr = validatorAddresses[i];
            if(validators[validatorAddr].isActive) {
                activeValidators[activeCount] = validatorAddr;
                activeCount++;
            }
        }
        
        assembly {
            mstore(activeValidators, activeCount)
        }
        
        return activeValidators;
    }

    function getValidatorCount() external view override returns (uint256) {
        return validatorCount;
    }

    function updateValidatorStats(address _validator, bool _success) public {
        require(msg.sender == address(consensusValidator), "Only consensus validator");
        require(users[_validator].role == UserRole.Validator, "Not a validator");
        require(validators[_validator].isActive, "Validator not active");

        validators[_validator].validationsCount++;
        if (_success) {
            validators[_validator].successfulValidations++;
        }

        emit ValidatorStatsUpdated(_validator, validators[_validator].validationsCount, validators[_validator].successfulValidations);
    }

    // Helper functions
    function checkIsRegistered(address _user) external view returns (bool) {
        return users[_user].isRegistered;
    }

    function checkRole(address _user) external view returns (UserRole) {
        return users[_user].role;
    }

    function checkIsActiveValidator(address _user) external view override returns (bool) {
        return users[_user].role == UserRole.Validator && validators[_user].isActive;
    }

    function setMinValidators(uint256 _minValidators) external onlyOwner {
        minValidators = _minValidators;
    }

    // Emergency functions
    function emergencyWithdraw(address _validator) external onlyOwner {
        require(users[_validator].role == UserRole.Validator, "Not a validator");
        require(validators[_validator].stakedAmount > 0, "No stake found");

        uint256 stakeToReturn = validators[_validator].stakedAmount;
        validators[_validator].stakedAmount = 0;
        validators[_validator].isActive = false;
        
        payable(_validator).transfer(stakeToReturn);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}