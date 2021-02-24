// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.6.6;

import "../BEP20Token.sol";

contract BytexToken is BEP20Token {
  constructor() public BEP20Token("Bytex Token", "BYX", 18, 20 * 1e6 * 1e18) {
  }
}
