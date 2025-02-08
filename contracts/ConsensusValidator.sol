// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../lib/DataMarketErrors.sol";
import "../lib/DataMarketInterface.sol";

contract ConsensusValidator is IConsensusValidator, Ownable, Pausable {
    using DataMarketErrors for *;

    struct Validator {
        bool isRegistered;
        uint256 stakedAmount;
        uint256 registrationDate;
        uint256 validationsCount;
        uint256 successfulValidations;
        bool isActive;
    }

    struct ValidationResult {
        bool consensusReached;
        bool approved;
        uint256 approvalCount;
        uint256 rejectionCount;
        uint256 startTime;
        uint256 endTime;
        uint256 validatorCount;
        mapping(address => bool) hasValidated;
        mapping(address => bool) validatorVotes;
    }

    uint256 public validatorCount;
    uint256 public minValidators = 3;
    uint256 public constant VALIDATION_PERIOD = 24 hours;
    uint256 public constant CLEANUP_DELAY = 7 days;
    uint256 public constant MINIMUM_STAKE = 0.0001 ether;
    uint256 private currentValidatorIndex;

    mapping(uint256 => address) private validatorAddresses;
    mapping(bytes32 => ValidationResult) public validations;
    mapping(address => Validator) public validators;

    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event ConsensusReached(bytes32 indexed transferId, bool approved);
    event ValidationSubmitted(bytes32 indexed transferId, address indexed validator, bool approved);
    event StakeWithdrawn(address indexed validator, uint256 amount);
    event ValidationCleaned(bytes32 indexed transferId);
    event ValidatorRegistered(address indexed validator, uint256 stake);
    event ValidatorStakeIncreased(address indexed validator, uint256 newStake);
    event ValidatorDeactivated(address indexed validator);

    constructor() Ownable(msg.sender) {}

    function registerAsValidator() external payable whenNotPaused {
        require(msg.value >= MINIMUM_STAKE, "Insufficient stake");
        require(!validators[msg.sender].isRegistered, "Already registered");

        validators[msg.sender] = Validator({
            isRegistered: true,
            stakedAmount: msg.value,
            registrationDate: block.timestamp,
            validationsCount: 0,
            successfulValidations: 0,
            isActive: true
        });

        validatorAddresses[currentValidatorIndex] = msg.sender;
        currentValidatorIndex++;
        validatorCount++;
        
        emit ValidatorRegistered(msg.sender, msg.value);
    }

    function increaseStake() external payable whenNotPaused {
        Validator storage validator = validators[msg.sender];
        require(validator.isRegistered, "Not a validator");
        require(validator.isActive, "Validator not active");

        validator.stakedAmount += msg.value;
        emit ValidatorStakeIncreased(msg.sender, validator.stakedAmount);
    }

    function withdrawStake() external whenNotPaused {
        Validator storage validator = validators[msg.sender];
        require(validator.isRegistered, "Not a validator");
        require(validator.isActive, "Validator not active");
        require(block.timestamp >= validator.registrationDate + 30 days, "Withdrawal locked");

        uint256 stakeToReturn = validator.stakedAmount;
        validator.stakedAmount = 0;
        validator.isActive = false;
        validatorCount--;

        payable(msg.sender).transfer(stakeToReturn);
        emit ValidatorDeactivated(msg.sender);
    }

    function removeValidator(address _validator) external onlyOwner {
        Validator storage validator = validators[_validator];
        require(validator.isRegistered, "Not a validator");
        require(validatorCount > minValidators, "Too few validators");
        require(validator.stakedAmount == 0, "Stake not withdrawn");

        validator.isRegistered = false;
        validator.isActive = false;
        validatorCount--;
        emit ValidatorRemoved(_validator);
    }

    function getValidationDetails(
        bytes32 _transferId
    )
        external
        view
        override
        returns (
            uint256 approvalCount,
            uint256 rejectionCount,
            bool consensusReached,
            bool approved,
            uint256 validationStartTime,
            uint256 totalValidatorCount
        )
    {
        ValidationResult storage validation = validations[_transferId];
        return (
            validation.approvalCount,
            validation.rejectionCount,
            validation.consensusReached,
            validation.approved,
            validation.startTime,
            validation.validatorCount
        );
    }

    function getValidatorAtIndex(uint256 _index) public view returns (address) {
        require(_index < currentValidatorIndex, "Index out of bounds");
        return validatorAddresses[_index];
    }

    function getAllActiveValidators() external view returns (address[] memory) {
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

    function initiateValidation(bytes32 _transferId) external override {
        if (validatorCount < minValidators)
            revert DataMarketErrors.InsufficientValidators();
        ValidationResult storage validation = validations[_transferId];

        if (validation.startTime != 0)
            revert DataMarketErrors.AlreadyInitialized();
        validation.startTime = block.timestamp;
        validation.validatorCount = validatorCount;
    }

    function validate(bytes32 _transferId, bool _approved) external override whenNotPaused {
        Validator storage validator = validators[msg.sender];
        require(validator.isRegistered && validator.isActive, "Not an active validator");

        ValidationResult storage validation = validations[_transferId];
        require(!validation.hasValidated[msg.sender], "Already validated");
        require(validation.startTime != 0, "Validation not initiated");
        require(block.timestamp <= validation.startTime + VALIDATION_PERIOD, "Period ended");
        require(!validation.consensusReached, "Consensus reached");

        validation.hasValidated[msg.sender] = true;
        validation.validatorVotes[msg.sender] = _approved;

        if (_approved) {
            validation.approvalCount++;
        } else {
            validation.rejectionCount++;
        }

        validator.validationsCount++;
        emit ValidationSubmitted(_transferId, msg.sender, _approved);

        checkConsensus(_transferId);
    }

    function checkConsensus(bytes32 _transferId) internal {
        ValidationResult storage validation = validations[_transferId];
        uint256 totalVotes = validation.approvalCount + validation.rejectionCount;

        if (totalVotes < validation.validatorCount / 2) {
            return;
        }

        uint256 threshold = (validation.validatorCount * 2) / 3;

        if (validation.approvalCount > threshold || validation.rejectionCount > threshold) {
            validation.consensusReached = true;
            validation.approved = validation.approvalCount > validation.rejectionCount;
            validation.endTime = block.timestamp;

            for (uint i = 0; i < validatorCount; i++) {
                address validatorAddress = getValidatorAtIndex(i);
                if (validation.hasValidated[validatorAddress]) {
                    Validator storage validator = validators[validatorAddress];
                    if (validation.validatorVotes[validatorAddress] == validation.approved) {
                        validator.successfulValidations++;
                    }
                }
            }

            emit ConsensusReached(_transferId, validation.approved);
        }
    }

    function hasValidConsensus(bytes32 _transferId) external view override returns (bool) {
        ValidationResult storage validation = validations[_transferId];
        return validation.consensusReached;
    }

    function setMinValidators(uint256 _minValidators) external onlyOwner {
        minValidators = _minValidators;
    }

    function hasValidated(
        bytes32 _transferId,
        address _validator
    ) external view returns (bool) {
        return validations[_transferId].hasValidated[_validator];
    }

    function cleanupValidation(bytes32 _transferId) external {
        ValidationResult storage validation = validations[_transferId];
        if (!validation.consensusReached)
            revert DataMarketErrors.ConsensusNotReached();
        if (block.timestamp < validation.endTime + CLEANUP_DELAY)
            revert DataMarketErrors.CleanupPeriodNotEnded();
        delete validations[_transferId];
        emit ValidationCleaned(_transferId);
    }

    function emergencyWithdraw(address _validator) external onlyOwner {
        Validator storage validator = validators[_validator];
        require(validator.isRegistered, "Not a validator");
        require(validator.stakedAmount > 0, "No stake found");

        uint256 stakeToReturn = validator.stakedAmount;
        validator.stakedAmount = 0;
        validator.isActive = false;
        
        payable(_validator).transfer(stakeToReturn);
    }

    function getValidatorCount() external view override returns (uint256) {
        return validatorCount;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
