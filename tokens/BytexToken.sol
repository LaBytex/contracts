// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.6.6;

import "../ERC20Token.sol";

contract BytexToken is ERC20Token {
  constructor() public ERC20Token("Bytex Token", "BYX", 18, 20 * 1e6 * 1e18) {
  }
}