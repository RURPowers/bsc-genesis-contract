// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/DoubleEndedQueueUpgradeable.sol";

import "./System.sol";

interface IStakeHub {
    function unbondPeriod() external view returns (uint256);
    function transferGasLimit() external view returns (uint256);
    function poolImplementation() external view returns (address);
}

contract StakePool is Initializable, ReentrancyGuardUpgradeable, ERC20Upgradeable, System {
    using CountersUpgradeable for CountersUpgradeable.Counter;
    using DoubleEndedQueueUpgradeable for DoubleEndedQueueUpgradeable.Bytes32Deque;

    /*----------------- constant -----------------*/
    uint256 public constant COMMISSION_RATE_BASE = 10_000; // 100%

    /*----------------- storage -----------------*/
    address public validator; // validator operator address
    uint256 private _totalPooledBNB; // total reward plus total BNB staked in the pool

    // hash of the unbond request => unbond request
    mapping(bytes32 => UnbondRequest) private _unbondRequests;
    // user => unbond request queue(hash of the request)
    mapping(address => DoubleEndedQueueUpgradeable.Bytes32Deque) private _unbondRequestsQueue;
    // user => locked shares
    mapping(address => uint256) private _lockedShares;
    // user => personal unbond sequence
    mapping(address => CountersUpgradeable.Counter) private _unbondSequence;
    // user => claimed govBNB balance
    mapping(address => uint256) private _govBNBBalance;

    // for slash
    bool private _freeze;
    uint256 private _remainingSlashBnbAmount;

    struct UnbondRequest {
        uint256 shares;
        uint256 bnbAmount;
        uint256 unlockTime;
    }

    /*----------------- events -----------------*/
    event Delegated(address indexed delegator, uint256 shares, uint256 bnbAmount);
    event Unbonded(address indexed delegator, uint256 shares, uint256 bnbAmount);
    event UnbondRequested(address indexed delegator, uint256 shares, uint256 bnbAmount, uint256 unlockTime);
    event UnbondClaimed(address indexed delegator, uint256 shares, uint256 bnbAmount);
    event RewardReceived(uint256 reward, uint256 commission);
    event PayFine(uint256 bnbAmount);

    /*----------------- external functions -----------------*/
    function initialize(address _validator, string memory _moniker) public payable initializer {
        string memory name_ = string.concat("stake ", _moniker, " credit");
        string memory symbol_ = string.concat("st", _moniker);
        __ERC20_init_unchained(name_, symbol_);

        validator = _validator;

        assert(msg.value != 0);
        _bootstrapInitialHolder(msg.value);
    }

    function delegate(address delegator) external payable onlyStakeHub returns (uint256) {
        require(!_freeze, "VALIDATOR_FROZEN");
        require(msg.value != 0, "ZERO_DEPOSIT");
        _govBNBBalance[delegator] += msg.value;
        return _stake(delegator, msg.value);
    }

    function undelegate(address delegator, uint256 shares) external onlyStakeHub returns (uint256, uint256) {
        require(shares != 0, "ZERO_AMOUNT");
        require(shares <= balanceOf(delegator), "INSUFFICIENT_BALANCE");

        _lockedShares[delegator] += shares;

        // calculate the BNB amount and update state
        uint256 bnbAmount = getPooledBNBByShares(shares);
        _burn(delegator, shares);
        _totalPooledBNB -= bnbAmount;
        uint256 govBNBAmount;
        if (bnbAmount > _govBNBBalance[delegator]) {
            govBNBAmount = _govBNBBalance[delegator];
            _govBNBBalance[delegator] = 0;
        } else {
            govBNBAmount = bnbAmount;
            _govBNBBalance[delegator] -= bnbAmount;
        }

        // add to the queue
        bytes32 hash = keccak256(abi.encodePacked(delegator, _useSequence(delegator)));

        uint256 unlockTime = block.timestamp + IStakeHub(STAKE_HUB_ADDR).unbondPeriod();
        UnbondRequest memory request = UnbondRequest({shares: shares, bnbAmount: bnbAmount, unlockTime: unlockTime});
        _unbondRequests[hash] = request;
        _unbondRequestsQueue[delegator].pushBack(hash);

        emit UnbondRequested(delegator, shares, bnbAmount, request.unlockTime);
        return (bnbAmount, govBNBAmount);
    }

    /**
     * @dev Unbond immediately without adding to the queue.
     * Only for redelegate process.
     */
    function unbond(address delegator, uint256 shares) external onlyStakeHub returns (uint256, uint256) {
        require(shares <= balanceOf(delegator), "INSUFFICIENT_BALANCE");

        // calculate the BNB amount and update state
        uint256 bnbAmount = getPooledBNBByShares(shares);
        _burn(delegator, shares);
        _totalPooledBNB -= bnbAmount;
        uint256 govBNBAmount;
        if (bnbAmount > _govBNBBalance[delegator]) {
            govBNBAmount = _govBNBBalance[delegator];
            _govBNBBalance[delegator] = 0;
        } else {
            govBNBAmount = bnbAmount;
            _govBNBBalance[delegator] -= bnbAmount;
        }

        uint256 _gasLimit = IStakeHub(STAKE_HUB_ADDR).transferGasLimit();
        (bool success,) = STAKE_HUB_ADDR.call{gas: _gasLimit, value: bnbAmount}("");
        require(success, "TRANSFER_FAILED");

        emit Unbonded(delegator, shares, bnbAmount);
        return (bnbAmount, govBNBAmount);
    }

    function claim(address payable delegator, uint256 number) external onlyStakeHub nonReentrant returns (uint256) {
        if (delegator == validator) {
            require(!_freeze, "VALIDATOR_FROZEN");
        }

        require(_unbondRequestsQueue[delegator].length() != 0, "NO_UNBOND_REQUEST");
        // number == 0 means claim all
        if (number == 0) {
            number = _unbondRequestsQueue[delegator].length();
        }
        if (number > _unbondRequestsQueue[delegator].length()) {
            number = _unbondRequestsQueue[delegator].length();
        }

        uint256 _totalShares;
        uint256 _totalBnbAmount;
        while (number != 0) {
            bytes32 hash = _unbondRequestsQueue[delegator].front();
            UnbondRequest memory request = _unbondRequests[hash];
            if (block.timestamp < request.unlockTime) {
                break;
            }

            _totalShares += request.shares;
            _totalBnbAmount += request.bnbAmount;

            // remove from the queue
            _unbondRequestsQueue[delegator].popFront();
            delete _unbondRequests[hash];

            number -= 1;
        }
        require(_totalShares != 0, "NO_CLAIMABLE_UNBOND_REQUEST");

        _lockedShares[delegator] -= _totalShares;
        uint256 _gasLimit = IStakeHub(STAKE_HUB_ADDR).transferGasLimit();
        (bool success,) = delegator.call{gas: _gasLimit, value: _totalBnbAmount}("");
        require(success, "CLAIM_FAILED");

        emit UnbondClaimed(delegator, _totalShares, _totalBnbAmount);
        return _totalBnbAmount;
    }

    function claimGovBnb(address delegator) external onlyStakeHub returns (uint256) {
        uint256 claimedGovBnbAmount = _govBNBBalance[delegator];
        uint256 dueGovBnbAmount = getPooledBNBByShares(balanceOf(delegator));
        require(dueGovBnbAmount > claimedGovBnbAmount, "NO_CLAIMABLE_GOV_BNB");

        _govBNBBalance[delegator] = dueGovBnbAmount;
        return dueGovBnbAmount - claimedGovBnbAmount;
    }

    function distributeReward(uint64 commissionRate) external payable onlyStakeHub {
        uint256 bnbAmount = msg.value;
        uint256 _commission = (bnbAmount * uint256(commissionRate)) / COMMISSION_RATE_BASE;
        uint256 _reward = bnbAmount - _commission;
        _totalPooledBNB += _reward;

        // mint reward to the validator
        uint256 shares = getSharesByPooledBNB(_commission);
        _totalPooledBNB += _commission;
        _mint(validator, shares);

        emit RewardReceived(_reward, _commission);
    }

    function slash(uint256 slashBnbAmount) external onlyStakeHub returns (uint256) {
        uint256 selfDelegation = balanceOf(validator);
        uint256 slashShares = getSharesByPooledBNB(slashBnbAmount);

        uint256 remainingSlashBnbAmount_;
        if (slashShares <= selfDelegation) {
            _totalPooledBNB -= slashBnbAmount;
            _burn(validator, slashShares);
        } else {
            uint256 selfDelegationBNB = getPooledBNBByShares(selfDelegation);
            _totalPooledBNB -= selfDelegationBNB;
            _burn(validator, selfDelegation);

            remainingSlashBnbAmount_ = slashBnbAmount - selfDelegationBNB;

            _freeze = true;
            _remainingSlashBnbAmount += remainingSlashBnbAmount_;
        }

        uint256 _gasLimit = IStakeHub(STAKE_HUB_ADDR).transferGasLimit();
        uint256 realSlashBnbAmount = slashBnbAmount - remainingSlashBnbAmount_;
        (bool success,) = SYSTEM_REWARD_ADDR.call{gas: _gasLimit, value: realSlashBnbAmount}("");
        require(success, "TRANSFER_FAILED");
        return realSlashBnbAmount;
    }

    function payFine() external payable {
        require(_freeze, "NOT_FROZEN");
        require(msg.value == _remainingSlashBnbAmount, "INVALID_AMOUNT");

        _freeze = false;
        _remainingSlashBnbAmount = 0;

        uint256 _gasLimit = IStakeHub(STAKE_HUB_ADDR).transferGasLimit();
        (bool success,) = SYSTEM_REWARD_ADDR.call{gas: _gasLimit, value: msg.value}("");
        require(success, "TRANSFER_FAILED");

        emit PayFine(msg.value);
    }

    /*----------------- view functions -----------------*/
    /**
     * @return the amount of shares that corresponds to `_bnbAmount` protocol-controlled BNB.
     */
    function getSharesByPooledBNB(uint256 bnbAmount) public view returns (uint256) {
        return (bnbAmount * totalSupply()) / _totalPooledBNB;
    }

    /**
     * @return the amount of BNB that corresponds to `_sharesAmount` token shares.
     */
    function getPooledBNBByShares(uint256 shares) public view returns (uint256) {
        return (shares * _totalPooledBNB) / totalSupply();
    }

    function totalPooledBNB() public view returns (uint256) {
        return _totalPooledBNB;
    }

    function unbondRequest(address delegator, uint256 _index) public view returns (UnbondRequest memory, uint256) {
        bytes32 hash = _unbondRequestsQueue[delegator].at(_index);
        return (_unbondRequests[hash], _unbondRequestsQueue[delegator].length());
    }

    function lockedShares(address delegator) public view returns (uint256) {
        return _lockedShares[delegator];
    }

    function unbondSequence(address delegator) public view returns (uint256) {
        return _unbondSequence[delegator].current();
    }

    function isFreeze() public view returns (bool) {
        return _freeze;
    }

    function remainingSlashBnbAmount() public view returns (uint256) {
        return _remainingSlashBnbAmount;
    }

    function getSelfDelegationBNB() public view returns (uint256) {
        return getPooledBNBByShares(balanceOf(validator));
    }

    /*----------------- internal functions -----------------*/
    function _bootstrapInitialHolder(uint256 initAmount) internal {
        assert(validator != address(0));
        assert(totalSupply() == 0);

        // mint initial tokens to the validator
        // shares is equal to the amount of BNB staked
        _totalPooledBNB = initAmount;
        emit Delegated(validator, initAmount, initAmount);
        _mint(validator, initAmount);
    }

    /**
     * @dev Process user deposit, mints liquid tokens and increase the pool staked BNB
     * @param delegator address of the delegator.
     * @param bnbAmount amount of BNB to stake.
     * @return amount of StBNB generated
     */
    function _stake(address delegator, uint256 bnbAmount) internal returns (uint256) {
        uint256 shares = getSharesByPooledBNB(bnbAmount);
        _totalPooledBNB += bnbAmount;
        emit Delegated(delegator, shares, bnbAmount);

        _mint(delegator, shares);
        return shares;
    }

    function _useSequence(address delegator) internal returns (uint256 current) {
        CountersUpgradeable.Counter storage sequence = _unbondSequence[delegator];
        current = sequence.current();
        sequence.increment();
    }

    function _transfer(address, address, uint256) internal pure override {
        revert("stBNB transfer is not supported");
    }

    function _approve(address, address, uint256) internal pure override {
        revert("stBNB approve is not supported");
    }
}
