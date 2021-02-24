// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.6.6;

import "./StakeWrapper.sol";

contract BytexBNBPool is StakeWrapper {

  /**
   * @dev initialize contract with required staking config
   */
  constructor(
    address _bytexToken, 
    uint256 _rateLimiter, 
    uint256 _unstakeFee, 
    uint256[] memory levelLimit, 
    uint256[] memory levelRate
  ) StakeWrapper(_bytexToken, _rateLimiter, _unstakeFee, levelLimit, levelRate) public {}

  /**
   * @dev wrapper for staking without referral
   */
  function stake() public payable {
    stake(address(0x0));
  }

  /**
   * @dev stake specified amount of tokens
   */
  function stake(address _referrer) public payable {
    uint256 stakeAmount = msg.value;
    address userAddr = msg.sender;
    require(stakeAmount >= 1 * 1e17, "Too low value");
    stakeHelper(userAddr, stakeAmount, _referrer);
  }

  /**
   * @dev wrapper to unstake user's all tokens
   */
  function unstake() public {
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
    safeSendValue(msg.sender, amount.mul(uint256(100).sub(unstakeFee)).div(100));

    emit UserAction('Unstake', user.addr, user.referrer, amount);
  }

  /**
   * @dev wrapper to withdraw the whole of accumulated platform fees
   */
  function withdrawFees() public onlyOwner returns (uint256) {
    return withdrawFees(owner(), platformFees);
  }

  /**
   * @dev withdraw specified amount of fee from accumulated platform fees
   */
  function withdrawFees(address _address, uint256 amount) public onlyOwner returns (uint256){
    platformFees = platformFees.sub(amount);
    return safeSendValue(address(uint160(_address)), amount);
  }

  /**
   * @dev user stake details
   */
  function user(address _address) view public returns (
    uint256 investment,
    uint256 lastClaim,
    address referrer,
    uint256 referralReward,
    uint256 totalReferrals,
    uint256 pendingRewards,
    uint256 tokenBalance,
    uint256 balance
  ) {
    investment = users[_address].investment;
    lastClaim = users[_address].lastClaim;
    referrer = users[_address].referrer;
    referralReward = users[_address].referralReward;
    totalReferrals = users[_address].totalReferrals;
    pendingRewards = claimableReward(_address);
    tokenBalance = bytexToken.balanceOf(_address);
    balance = _address.balance;
  }

  /**
   * @dev transfer BNB to given user address
   */
  function safeSendValue(address payable _to, uint256 amount) internal returns (uint256 actualAmount) {
    actualAmount = (amount < address(this).balance) ? amount : address(this).balance;
    _to.transfer(actualAmount);
  }

}