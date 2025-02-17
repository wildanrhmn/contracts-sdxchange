// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../lib/DataMarketErrors.sol";
import "../lib/DataMarketInterface.sol";


contract ConsensusValidator is IConsensusValidator, Ownable, Pausable {
    using DataMarketErrors for *;

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

    uint256 public minValidators = 3;
    uint256 public constant VALIDATION_PERIOD = 24 hours;
    uint256 public constant CLEANUP_DELAY = 7 days;

    mapping(bytes32 => ValidationResult) public validations;
    IUserManager public userManager;

    event ConsensusReached(bytes32 indexed transferId, bool approved);
    event ValidationSubmitted(bytes32 indexed transferId, address indexed validator, bool approved);
    event ValidationCleaned(bytes32 indexed transferId);

    constructor(address _userManager) Ownable(msg.sender) {
        userManager = IUserManager(_userManager);
    }

    function initiateValidation(bytes32 _transferId) external override {
        uint256 validatorCount = userManager.getValidatorCount();
        if (validatorCount < minValidators)
            revert DataMarketErrors.InsufficientValidators();

        ValidationResult storage validation = validations[_transferId];
        if (validation.startTime != 0)
            revert DataMarketErrors.AlreadyInitialized();

        validation.startTime = block.timestamp;
        validation.validatorCount = validatorCount;
    }

    function validate(bytes32 _transferId, bool _approved) external override whenNotPaused {
        require(userManager.checkIsActiveValidator(msg.sender), "Not an active validator");

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

            address[] memory activeValidators = userManager.getAllActiveValidators();
            for (uint i = 0; i < activeValidators.length; i++) {
                if (validation.hasValidated[activeValidators[i]]) {
                    userManager.updateValidatorStats(
                        activeValidators[i],
                        validation.validatorVotes[activeValidators[i]] == validation.approved
                    );
                }
            }

            emit ConsensusReached(_transferId, validation.approved);
        }
    }

    // Rest of the functions remain mostly the same, but remove validator management
    function getValidationDetails(
        bytes32 _transferId
    ) external view override returns (
        uint256 approvalCount,
        uint256 rejectionCount,
        bool consensusReached,
        bool approved,
        uint256 validationStartTime,
        uint256 totalValidatorCount
    ) {
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

    function hasValidConsensus(bytes32 _transferId) external view override returns (bool) {
        ValidationResult storage validation = validations[_transferId];
        return validation.consensusReached;
    }

    function setMinValidators(uint256 _minValidators) external onlyOwner {
        minValidators = _minValidators;
    }

    function hasValidated(bytes32 _transferId, address _validator) external view returns (bool) {
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

    function setUserManager(address _userManager) external onlyOwner {
        userManager = IUserManager(_userManager);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}