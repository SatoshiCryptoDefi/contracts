// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./SafeMath.sol";
import "./IBEP20.sol";
import "./SafeBEP20.sol";
import "./Ownable.sol";
import "./ISatoshiReferral.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./SATOSHIToken.sol";

// MasterChef is the master of Satoshi. He can make Satoshi and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once SATOSHI is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        uint256 rewardLockedUp;  // Reward locked up.
        //
        // We do some fancy math here. Basically, any point in time, the amount of SATOSHIs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accSatoshiPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accSatoshiPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. SATOSHIs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that SATOSHIs distribution occurs.
        uint256 accSatoshiPerShare;   // Accumulated SATOSHIs per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
    }

    // The SATOSHI TOKEN!
    SatoshiToken public satoshi;
    // Team address.
    address public teamAddr;
    // Marketing address.
    address public marketingAddr;
    // Deposit Fee address
    address public feeAddress;
    // SATOSHI tokens created per block.
    uint256 public satoshiPerBlock;
    // Bonus muliplier for early satoshi makers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Max harvest interval: 14 days.
    uint256 public constant MAXIMUM_HARVEST_INTERVAL = 14 days;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when SATOSHI mining starts.
    uint256 public startBlock;
    // Total locked up rewards
    uint256 public totalLockedUpRewards;

    // Satoshi referral contract address.
    ISatoshiReferral public satoshiReferral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 100;
    // Max referral commission rate: 10%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 1000;

    uint256 public weekLockStartTime = 1631052001;
    uint256 public constant WEEK_DURATION = 7 days;
    uint256 public constant DAY_DURATION = 1 days;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmissionRateUpdated(address indexed caller, uint256 previousAmount, uint256 newAmount);
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);
    event RewardLockedUp(address indexed user, uint256 indexed pid, uint256 amountLockedUp);

    constructor(
        SatoshiToken _satoshi,
        address _teamAddr,
        address _marketingAddr,
        address _feeAddress,
        uint256 _satoshiPerBlock,
        uint256 _startBlock
    ) public {
        satoshi = _satoshi;
        teamAddr = _teamAddr;
        marketingAddr = _marketingAddr;
        feeAddress = _feeAddress;
        satoshiPerBlock = _satoshiPerBlock;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 10000, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accSatoshiPerShare: 0,
            depositFeeBP: _depositFeeBP
        }));
    }

    // Update the given pool's SATOSHI allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 10000, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending SATOSHIs on frontend.
    function pendingSatoshi(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSatoshiPerShare = pool.accSatoshiPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 satoshiReward = multiplier.mul(satoshiPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accSatoshiPerShare = accSatoshiPerShare.add(satoshiReward.mul(1e12).div(lpSupply));
        }
        uint256 pending = user.amount.mul(accSatoshiPerShare).div(1e12).sub(user.rewardDebt);
        return pending.add(user.rewardLockedUp);
    }

    // View function to see if user can harvest SATOSHIs.
    function canHarvest() public view returns (bool) {
        if (block.timestamp < weekLockStartTime) 
            return false;

        uint256 weeksSec = block.timestamp.sub(weekLockStartTime).div(WEEK_DURATION).mul(WEEK_DURATION);
        return block.timestamp.sub(weekLockStartTime).sub(weeksSec) < DAY_DURATION;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 satoshiReward = multiplier.mul(satoshiPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        satoshi.mint(teamAddr, satoshiReward.div(23));
        satoshi.mint(marketingAddr, satoshiReward.div(23));
        satoshi.mint(address(this), satoshiReward);
        pool.accSatoshiPerShare = pool.accSatoshiPerShare.add(satoshiReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for SATOSHI allocation.
    function deposit(uint256 _pid, uint256 _amount, address _referrer) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (_amount > 0 && address(satoshiReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            satoshiReferral.recordReferral(msg.sender, _referrer);
        }
        payOrLockupPendingSatoshi(_pid);
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (address(pool.lpToken) == address(satoshi)) {
                uint256 transferTax = _amount.mul(satoshi.transferTaxRate()).div(10000);
                _amount = _amount.sub(transferTax);
            }
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            }else{
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accSatoshiPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        payOrLockupPendingSatoshi(_pid);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accSatoshiPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardLockedUp = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function _weekHarvestTimeFromNow() private view returns (uint256) {
        if (block.timestamp <= weekLockStartTime) 
            return weekLockStartTime;

        uint256 weeks1 = block.timestamp.sub(weekLockStartTime).div(WEEK_DURATION).add(1);
        return weeks1.mul(WEEK_DURATION).add(weekLockStartTime);
    }

    // Pay or lockup pending SATOSHIs.
    function payOrLockupPendingSatoshi(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 pending = user.amount.mul(pool.accSatoshiPerShare).div(1e12).sub(user.rewardDebt);
        if (canHarvest()) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 totalRewards = pending.add(user.rewardLockedUp);

                // reset lockup
                totalLockedUpRewards = totalLockedUpRewards.sub(user.rewardLockedUp);
                user.rewardLockedUp = 0;

                // send rewards
                safeSatoshiTransfer(msg.sender, totalRewards);
                payReferralCommission(msg.sender, totalRewards);
            }
        } else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            totalLockedUpRewards = totalLockedUpRewards.add(pending);
            emit RewardLockedUp(msg.sender, _pid, pending);
        }
    }
    // Safe satoshi transfer function, just in case if rounding error causes pool to not have enough SATOSHIs.
    function safeSatoshiTransfer(address _to, uint256 _amount) internal {
        uint256 satoshiBal = satoshi.balanceOf(address(this));
        if (_amount > satoshiBal) {
            satoshi.transfer(_to, satoshiBal);
        } else {
            satoshi.transfer(_to, _amount);
        }
    }

    // Update team address by the previous team address.
    function setTeamAddress(address _teamAddress) public {
        require(msg.sender == teamAddr, "team: FORBIDDEN");
        require(_teamAddress != address(0), "team: ZERO");
        teamAddr = _teamAddress;
    }

    // Update marketing address by the previous marketing address.
    function setMarketingAddress(address _marketingAddr) public {
        require(msg.sender == marketingAddr, "marketing: FORBIDDEN");
        require(_marketingAddr != address(0), "marketing: ZERO");
        marketingAddr = _marketingAddr;
    }

    function setFeeAddress(address _feeAddress) public{
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        require(_feeAddress != address(0), "setFeeAddress: ZERO");
        feeAddress = _feeAddress;
    }

    //Pancake has to add hidden dummy pools inorder to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _satoshiPerBlock) public onlyOwner {
        massUpdatePools();
        emit EmissionRateUpdated(msg.sender, satoshiPerBlock, _satoshiPerBlock);
        satoshiPerBlock = _satoshiPerBlock;
    }

    // Update the satoshi referral contract address by the owner
    function setSatoshiReferral(ISatoshiReferral _satoshiReferral) public onlyOwner {
        satoshiReferral = _satoshiReferral;
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate) public onlyOwner {
        require(_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE, "setReferralCommissionRate: invalid referral commission rate basis points");
        referralCommissionRate = _referralCommissionRate;
    }

    function setStartBlock(uint256 _startBlock) public onlyOwner {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {            
            PoolInfo storage pool = poolInfo[pid];
            if (pool.lastRewardBlock == startBlock) {
                pool.lastRewardBlock = _startBlock;
            }
        }

        startBlock = _startBlock;
    }

    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(satoshiReferral) != address(0) && referralCommissionRate > 0) {
            address referrer = satoshiReferral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);

            if (referrer != address(0) && commissionAmount > 0) {
                satoshi.mint(referrer, commissionAmount);
                satoshiReferral.recordReferralCommission(referrer, commissionAmount);
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }

    // Update weekLockStartTime by the owner
    function setWeekLockStartTime(uint256 _weekLockStartTime) public onlyOwner {
        weekLockStartTime = _weekLockStartTime;
    }
}