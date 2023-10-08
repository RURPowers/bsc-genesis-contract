pragma solidity ^0.8.10;

interface StakeHub {
    event Claimed(address indexed operatorAddress, address indexed delegator, uint256 bnbAmount);
    event CommissionRateEdited(address indexed operatorAddress, uint256 commissionRate);
    event ConsensusAddressEdited(address indexed oldAddress, address indexed newAddress);
    event Delegated(address indexed operatorAddress, address indexed delegator, uint256 bnbAmount);
    event DescriptionEdited(address indexed operatorAddress);
    event Redelegated(
        address indexed srcValidator, address indexed dstValidator, address indexed delegator, uint256 bnbAmount
    );
    event SecurityFundClaimed(address indexed operatorAddress, uint256 sharesAmount);
    event SecurityFundWithdrawRequested(address indexed operatorAddress, uint256 sharesAmount);
    event StakingPaused();
    event StakingResumed();
    event Undelegated(address indexed operatorAddress, address indexed delegator, uint256 bnbAmount);
    event ValidatorCreated(
        address indexed consensusAddress, address indexed operatorAddress, address indexed poolModule, bytes voteAddress
    );
    event ValidatorJailed(address indexed operatorAddress);
    event ValidatorSlashed(
        address indexed operatorAddress, uint256 slashAmount, uint256 slashHeight, uint256 jailUntil, uint8 slashType
    );
    event ValidatorUnjailed(address indexed operatorAddress);
    event VoteAddressEdited(address indexed operatorAddress, bytes newVoteAddress);
    event paramChange(string key, bytes value);

    struct Validator {
        address consensusAddress;
        address feeAddress;
        address BBCFeeAddress;
        uint64 votingPower;
        bool jailed;
        uint256 incoming;
    }

    struct Commission {
        uint256 rate;
        uint256 maxRate;
        uint256 maxChangeRate;
    }

    struct Description {
        string moniker;
        string identity;
        string website;
        string details;
    }

    function BLS_PUBKEY_LENGTH() external view returns (uint256);
    function BLS_SIG_LENGTH() external view returns (uint256);
    function GOVERNANCE_ADDR() external view returns (address);
    function GOV_HUB_ADDR() external view returns (address);
    function INIT_DOUBLE_SIGN_JAIL_TIME() external view returns (uint256);
    function INIT_DOUBLE_SIGN_SLASH_AMOUNT() external view returns (uint256);
    function INIT_DOWNTIME_JAIL_TIME() external view returns (uint256);
    function INIT_DOWNTIME_SLASH_AMOUNT() external view returns (uint256);
    function INIT_MAX_ELECTED_VALIDATORS() external view returns (uint256);
    function INIT_MAX_EVIDENCE_AGE() external view returns (uint256);
    function INIT_MIN_DELEGATION_BNB_CHANGE() external view returns (uint256);
    function INIT_MIN_SELF_DELEGATION_BNB() external view returns (uint256);
    function INIT_TRANSFER_GAS_LIMIT() external view returns (uint256);
    function INIT_UNBOND_PERIOD() external view returns (uint256);
    function SLASH_CONTRACT_ADDR() external view returns (address);
    function STAKE_HUB_ADDR() external view returns (address);
    function SYSTEM_REWARD_ADDR() external view returns (address);
    function VALIDATOR_CONTRACT_ADDR() external view returns (address);
    function bscChainID() external view returns (uint16);
    function claim(address validator, uint256 requestNumber) external;
    function claimSecurityFund() external;
    function consensusToOperator(address) external view returns (address);
    function createValidator(
        address consensusAddress,
        bytes memory voteAddress,
        bytes memory blsProof,
        Commission memory commission,
        Description memory description
    ) external payable;
    function delegate(address validator) external payable;
    function distributeReward(address consensusAddress) external payable;
    function doubleSignJailTime() external view returns (uint256);
    function doubleSignSlash(address consensusAddress, uint256 height, uint256 evidenceTime) external;
    function doubleSignSlashAmount() external view returns (uint256);
    function downtimeJailTime() external view returns (uint256);
    function downtimeSlash(address consensusAddress, uint256 height) external;
    function downtimeSlashAmount() external view returns (uint256);
    function editCommissionRate(address validator, uint256 commissionRate) external;
    function editConsensusAddress(address newConsensus) external;
    function editDescription(Description memory description) external;
    function editVoteAddress(bytes memory newVoteAddress, bytes memory blsProof) external;
    function eligibleValidatorVoteAddrs(uint256) external view returns (bytes memory);
    function eligibleValidators(uint256)
        external
        view
        returns (
            address consensusAddress,
            address feeAddress,
            address BBCFeeAddress,
            uint64 votingPower,
            bool jailed,
            uint256 incoming
        );
    function getEligibleValidators() external view returns (Validator[] memory, bytes[] memory);
    function getValidatorBasicInfo(address operatorAddress)
        external
        view
        returns (address consensusAddress, address poolModule, bytes memory voteAddress, bool jailed, uint256 jailUntil);
    function getValidatorCommission(address operatorAddress) external view returns (Commission memory);
    function getValidatorDescription(address operatorAddress) external view returns (Description memory);
    function getValidatorWithVotingPower(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory consensusAddrs, uint256[] memory votingPowers, uint256 totalLength);
    function initialize() external;
    function isPaused() external view returns (bool);
    function lockToGovernance(address operatorAddress, address from, uint256 _sharesAmount)
        external
        returns (uint256);
    function maliciousVoteSlash(bytes memory _voteAddr, uint256 height) external;
    function maxElectedValidators() external view returns (uint256);
    function maxEvidenceAge() external view returns (uint256);
    function minDelegationBNBChange() external view returns (uint256);
    function minSelfDelegationBNB() external view returns (uint256);
    function pauseStaking() external;
    function poolImplementation() external view returns (address);
    function redelegate(address srcValidator, address dstValidator, uint256 _sharesAmount) external;
    function resumeStaking() external;
    function slashRecords(bytes32)
        external
        view
        returns (uint256 slashAmount, uint256 slashHeight, uint256 jailUntil, uint8 slashType);
    function submitSecurityFundWithdrawRequest(uint256 _sharesAmount) external;
    function transferGasLimit() external view returns (uint256);
    function unbondPeriod() external view returns (uint256);
    function undelegate(address validator, uint256 _sharesAmount) external;
    function unjail(address validator) external;
    function updateEligibleValidators(address[] memory validators, uint64[] memory votingPowers) external;
    function updateParam(string memory key, bytes memory value) external;
    function voteToOperator(bytes memory) external view returns (address);
    function withdrawRequests(address) external view returns (uint256 sharesAmount, uint256 unlockTime);
}

