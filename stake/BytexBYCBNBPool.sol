// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.6.6;

import "./StakeWrapper.sol";

contract BytexBYCBNBPool is StakeWrapper {

  /**
   * @dev initialize contract with required staking config
   */
  constructor(
    address _bytexToken, 
    address _stakingToken, 
    uint256 _rateLimiter, 
    uint256[] memory levelLimit, 
    uint256[] memory levelRate
  ) StakeWrapper(_bytexToken, _stakingToken, _rateLimiter, levelLimit, levelRate) public {
  }

}