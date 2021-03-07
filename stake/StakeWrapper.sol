// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.6.6;

import "../SafeMath.sol";
import "../IBEP20.sol";
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
  uint256 public unstakeFee = 5;

  uint256 constant REWARD_INTERVAL = 1 days;
  uint256 constant REF_REWARD_PERCENT = 10;

  mapping(address => User) public users;
  Level[] public levels;
  IBEP20 public bytexToken; 

  event UserAction(string _type, address indexed _user, uint256 _amount);
  event LevelChanged(uint256 _newLevel, uint256 _timestamp);

  /**
   * @dev initialize contract with required staking config
   */
  constructor(
    address _bytexToken, 
    uint256 _rateLimiter, 
    uint256 _unstakeFee, 
    uint256[] memory levelLimit, 
    uint256[] memory levelRate
  ) public {

    bytexToken = IBEP20(_bytexToken);

    User storage user = users[msg.sender];
    user.exists = true;
    user.addr = msg.sender;
    user.investment = 0;
    user.lastClaim = block.timestamp;

    rateLimiter = _rateLimiter;
    unstakeFee = _unstakeFee;
    lastMintTime = block.timestamp;
    
    for (uint8 i=0; i<levelLimit.length; ++i) {
      levels.push(Level(levelLimit[i], levelRate[i], 0, 0));
    }
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
   * @dev claim user rewards and update the contract staking progress
   */
  function claimReward() public {
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
                .div(REWARD_INTERVAL)
                .mul(levels[currentLevel].rate)
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
    safeTokenTransfer(user.addr, reward);

    emit UserAction('ClaimReward', user.addr, reward);
  }

  /**
   * @dev - calculate claimable rewards for function caller
   */
  function claimableReward() public view returns (uint256) {
    return claimableReward(msg.sender);
  }

  /**
   * @dev - calculate claimable rewards for given wallet address
   */
  function claimableReward(address _address) public view returns (uint256 reward) {
    User memory user = users[_address];
    uint256 lastClaim = user.lastClaim;
    for (uint256 lvl = 0; lvl <= currentLevel; ++lvl) {
      uint256 time = (levels[lvl].completeTime == 0) ? block.timestamp : levels[lvl].completeTime;
      if (users[_address].lastClaim >= time) {
        continue;
      }
      reward = reward.add(
        user.investment
          .mul(time.sub(lastClaim))
          .div(REWARD_INTERVAL)
          .mul(levels[lvl].rate)
          .div(rateLimiter)
      );
      if (time == block.timestamp) {
        break;
      }
      lastClaim = time;
    }
  }

  /**
   * @dev view current status of staking
   */
  function stats() view public returns (
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
  function safeTokenTransfer(address _to, uint256 _amount) internal returns (uint256 amount) {
    uint256 balance = bytexToken.balanceOf(address(this));
    amount = (_amount > balance) ? balance : _amount;
    bytexToken.transfer(_to, amount);
  }

}
