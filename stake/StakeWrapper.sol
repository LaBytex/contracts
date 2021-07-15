// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.6.6;

import "../SafeMath.sol";
import "../IERC20.sol";
import "../Ownable.sol";

contract StakeWrapper is Ownable{

  using SafeMath for uint256;

  struct Level {
    uint limit;
    uint rate;
    uint alloted;
    uint completeTime;
  }
    
  struct User {
    uint256 investment;
    uint256 lastClaim;
    address addr;
    bool exists;
  }

  uint256 public totalStaked = 0;
  uint256 public platformFees = 0;
  uint256 public lastMintTime;
  uint256 public rateLimiter;
  uint256 public currentLevel = 0;
  uint256 public unstakeFee;


  uint256 constant REWARD_INTERVAL = 1 days;

  mapping(address => User) public users;
  Level[] public levels;
  IERC20 public bytexToken; 
  IERC20 public stakingToken;

  event UserAction(string _type, address indexed _user, uint256 _amount);
  event LevelChanged(uint256 _newLevel, uint256 _timestamp);

  /**
   * @dev initialize contract with required staking config
   */
  constructor(
    address _bytexToken,
    address _stakingToken, 
    uint256 _rateLimiter, 
    uint256[] memory levelLimit, 
    uint256[] memory levelRate
  ) public {

    bytexToken = IERC20(_bytexToken);
    stakingToken = IERC20(_stakingToken);

    User storage user = users[msg.sender];
    user.exists = true;
    user.addr = msg.sender;
    user.investment = 0;
    user.lastClaim = block.timestamp;

    rateLimiter = _rateLimiter;
    lastMintTime = block.timestamp;
    
    for (uint8 i=0; i<levelLimit.length; ++i) {
      levels.push(Level(levelLimit[i], levelRate[i], 0, 0));
    }
  }

  /**
   * @dev stake specified amount of tokens
   */
  function stake(uint256 stakeAmount) external {
    address userAddr = msg.sender;
    stakeHelper(userAddr, stakeAmount);
    stakingToken.transferFrom(userAddr, address(this), stakeAmount);
  }

  /**
   * @dev stake specified amount of tokens
   */
  function stakeHelper(address userAddr, uint256 stakeAmount) internal {
    require(userAddr != owner(), "Owner can't stake");
    updateAlloted();

    if (!users[userAddr].exists) {
      register(userAddr, stakeAmount);
    } else {
      claimRewardHelper();
      users[userAddr].investment = users[userAddr].investment.add(stakeAmount);
    }
    totalStaked = totalStaked.add(stakeAmount);
    platformFees = platformFees.add(stakeAmount.mul(unstakeFee).div(100));
    emit UserAction('Stake', userAddr, stakeAmount);
  }

  /**
   * @dev on user's initial stake setup user details in contract
   */
  function register(address userAddr, uint256 amount) internal {
    User storage user = users[userAddr];
    user.exists = true;
    user.addr = userAddr;
    user.investment = amount;
    user.lastClaim = block.timestamp;
  }

  /**
   * @dev wrapper to unstake user's all tokens
   */
  function unstakeAll() external {
    unstake(users[msg.sender].investment);
  }

  /**
   * @dev unstake specified amount of tokens from user stake
   */
  function unstake(uint256 amount) public {
    updateAlloted();
    User storage user = users[msg.sender];
    require(user.exists, 'Invalid User');

    claimRewardHelper();
    totalStaked = totalStaked.sub(amount);
    user.investment = user.investment.sub(amount, 'Unstake: Insufficient funds');
    safeTokenTransfer(stakingToken, msg.sender, amount.mul(uint256(100).sub(unstakeFee)).div(100));
    emit UserAction('Unstake', user.addr, amount);
  }

  /**
   * @dev claim user rewards and update the contract staking progress
   */
  function claimReward() external {
    updateAlloted();
    claimRewardHelper();
  }

  /**
   * @dev - update alloted tokens and check if new level is reached
   */
  function updateAlloted() internal {
    uint256 timePassed = block.timestamp.sub(lastMintTime);
    if (timePassed == 0) {
      return;
    }
    if (totalStaked != 0) {
      uint256 toAllot =
              totalStaked
                .mul(timePassed)
                .mul(levels[currentLevel].rate)
                .div(REWARD_INTERVAL)
                .div(rateLimiter);

      levels[currentLevel].alloted = levels[currentLevel].alloted.add(toAllot);

      if (levels[currentLevel].alloted >= levels[currentLevel].limit && currentLevel < (levels.length - 1)) {
        uint256 prevLevelOverAlloted = levels[currentLevel].alloted.sub(levels[currentLevel].limit);
        levels[currentLevel].alloted = levels[currentLevel].limit;
        levels[currentLevel].completeTime = block.timestamp;
        currentLevel++;

        levels[currentLevel].alloted = prevLevelOverAlloted;
        emit LevelChanged(currentLevel, block.timestamp);
      }
    }
    lastMintTime = block.timestamp;
  }

  /**
   * @dev - claim user's staking rewards
   */
  function claimRewardHelper() internal {
    User storage user = users[msg.sender];

    require(user.exists, 'Invalid User');
    uint256 reward = claimableReward(msg.sender);
    user.lastClaim = block.timestamp;
    safeTokenTransfer(bytexToken, user.addr, reward);

    emit UserAction('ClaimReward', user.addr, reward);
  }

  /**
   * @dev - calculate claimable rewards for given wallet address
   */
  function claimableReward(address _address) public view returns (uint256 reward) {
    User memory user = users[_address];
    uint256 currentLvlClaimStart = user.lastClaim; // to calculate rewards based on time in each level
    for (uint256 lvl = 0; lvl <= currentLevel; ++lvl) {
      uint256 time = (levels[lvl].completeTime == 0) ? block.timestamp : levels[lvl].completeTime;
      if (users[_address].lastClaim >= time) {
        continue;
      }
      reward = reward.add(
        user.investment
          .mul(time.sub(currentLvlClaimStart))
          .mul(levels[lvl].rate)
          .div(REWARD_INTERVAL)
          .div(rateLimiter)
      );
      if (time == block.timestamp) {
        break;
      }
      currentLvlClaimStart = time; // update currentlvlClaimStart to the processed level completion time
    }
  }

  /**
   * @dev - set the withdrawal fee for the pool upto 5%
   */
  function setWithdrawalFees(uint256 fee) external onlyOwner {
    require(fee <= 5, "Fee cannot be over 5%");
    unstakeFee = fee;
  }

  /**
   * @dev wrapper to withdraw the whole of accumulated platform fees
   */
  function withdrawAllFees() external onlyOwner returns (uint256) {
    return withdrawFees(owner(), platformFees);
  }

  /**
   * @dev withdraw specified amount of fee from accumulated platform fees
   */
  function withdrawFees(address _address, uint256 amount) public onlyOwner returns (uint256){
    platformFees = platformFees.sub(amount);
    return safeTokenTransfer(stakingToken, _address, amount);
  }

  /**
   * @dev user stake details
   */
  function user(address _address) view external returns (
    uint256 investment,
    uint256 lastClaim,
    uint256 pendingRewards,
    uint256 tokenBalance,
    uint256 balance
  ) {
    investment = users[_address].investment;
    lastClaim = users[_address].lastClaim;
    pendingRewards = claimableReward(_address);
    tokenBalance = bytexToken.balanceOf(_address);
    balance = stakingToken.balanceOf(_address);
  }

  /**
   * @dev view current status of staking
   */
  function stats() view external returns (
    uint256 level,
    uint256 levelYield,
    uint256 levelSupply,
    uint256 levelAlloted,
    uint256 staked,
    uint256 fees
  ) {
    level = currentLevel;
    levelYield = levels[currentLevel].rate;
    levelSupply = levels[currentLevel].limit;
    levelAlloted = levels[currentLevel].alloted;
    staked = totalStaked;
    fees = platformFees;
  }

  /**
   * @dev transfer reward tokens to given user address
   */
  function safeTokenTransfer(IERC20 _erc20Token, address _to, uint256 _amount) internal returns (uint256 amount) {
    uint256 balance = _erc20Token.balanceOf(address(this));
    amount = (_amount > balance) ? balance : _amount;
    _erc20Token.transfer(_to, amount);
  }

}