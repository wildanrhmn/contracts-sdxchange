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
    }

    struct ValidatorStats {
        uint256 totalParticipation;
        uint256 correctValidations;
    }

    uint256 public validatorCount;
    uint256 public constant VALIDATION_PERIOD = 24 hours;
    uint256 public minValidators = 3;
    uint256 public constant CLEANUP_DELAY = 7 days;
    uint256 public constant MINIMUM_STAKE = 0.0001 ether;

    mapping(bytes32 => ValidationResult) public validations;
    mapping(address => bool) public validators;
    mapping(address => uint256) public validatorStake;
    mapping(address => ValidatorStats) public validatorStats;

    event ValidatorAdded(address indexed validator);
    event ValidatorRemoved(address indexed validator);
    event ConsensusReached(bytes32 indexed transferId, bool approved);
    event ValidationSubmitted(bytes32 indexed transferId, address indexed validator, bool approved);
    event StakeWithdrawn(address indexed validator, uint256 amount);
    event ValidationCleaned(bytes32 indexed transferId);

    constructor() Ownable(msg.sender) {}

    function hasValidConsensus(bytes32 _transferId) external view override returns (bool) {
        ValidationResult storage validation = validations[_transferId];
        return validation.consensusReached;
    }

    function getValidatorCount() external view override returns (uint256) {
        return validatorCount;
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

    function initiateValidation(bytes32 _transferId) external override {
        if (validatorCount < minValidators)
            revert DataMarketErrors.InsufficientValidators();
        ValidationResult storage validation = validations[_transferId];

        if (validation.startTime != 0)
            revert DataMarketErrors.AlreadyInitialized();
        validation.startTime = block.timestamp;
        validation.validatorCount = validatorCount;
    }

    function validate(
        bytes32 _transferId,
        bool _approved
    ) external override whenNotPaused {
        if (!validators[msg.sender]) revert DataMarketErrors.NotValidator();

        ValidationResult storage validation = validations[_transferId];

        if (validation.hasValidated[msg.sender])
            revert DataMarketErrors.AlreadyValidated();
        if (validation.startTime == 0)
            revert DataMarketErrors.TransferNotFound();
        if (block.timestamp > validation.startTime + VALIDATION_PERIOD)
            revert DataMarketErrors.ValidationPeriodEnded();
        if (validation.consensusReached)
            revert DataMarketErrors.ConsensusAlreadyReached();

        validation.hasValidated[msg.sender] = true;

        if (_approved) {
            validation.approvalCount++;
        } else {
            validation.rejectionCount++;
        }

        emit ValidationSubmitted(_transferId, msg.sender, _approved);

        checkConsensus(_transferId);
    }

    function addValidator(address _validator) external payable onlyOwner {
        if (_validator == address(0)) revert DataMarketErrors.NotValidator();
        if (validators[_validator]) revert DataMarketErrors.AlreadyValidated();
        if (msg.value < MINIMUM_STAKE)
            revert DataMarketErrors.InsufficientStake();

        validators[_validator] = true;
        validatorStake[_validator] = msg.value;
        validatorCount++;
        emit ValidatorAdded(_validator);
    }

    function withdrawStake() external {
        if (!validators[msg.sender]) revert DataMarketErrors.NotValidator();
        uint256 stake = validatorStake[msg.sender];
        validatorStake[msg.sender] = 0;
        payable(msg.sender).transfer(stake);
        emit StakeWithdrawn(msg.sender, stake);
    }

    function removeValidator(address _validator) external onlyOwner {
        if (!validators[_validator]) revert DataMarketErrors.NotValidator();
        if (validatorCount <= minValidators)
            revert DataMarketErrors.InsufficientValidators();

        if (validatorStake[_validator] > 0)
            revert DataMarketErrors.StakeNotWithdrawn();

        validators[_validator] = false;
        validatorCount--;
        emit ValidatorRemoved(_validator);
    }

    function checkConsensus(bytes32 _transferId) internal {
        ValidationResult storage validation = validations[_transferId];
        uint256 totalVotes = validation.approvalCount +
            validation.rejectionCount;

        if (totalVotes < validation.validatorCount / 2) {
            return;
        }

        uint256 threshold = (validation.validatorCount * 2) / 3;

        if (validation.approvalCount > threshold) {
            validation.consensusReached = true;
            validation.approved = true;
            validation.endTime = block.timestamp;
            emit ConsensusReached(_transferId, true);
        } else if (validation.rejectionCount > threshold) {
            validation.consensusReached = true;
            validation.approved = false;
            validation.endTime = block.timestamp;
            emit ConsensusReached(_transferId, false);
        }
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
        if (!validators[_validator]) revert DataMarketErrors.NotValidator();
        uint256 stake = validatorStake[_validator];
        if (stake == 0) revert DataMarketErrors.NoStakeFound();

        validatorStake[_validator] = 0;
        payable(_validator).transfer(stake);
    }

    function updateValidatorStats(
        address _validator,
        bool _matchedConsensus
    ) internal {
        ValidatorStats storage stats = validatorStats[_validator];
        stats.totalParticipation++;
        if (_matchedConsensus) {
            stats.correctValidations++;
        }
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
