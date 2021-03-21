// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.6.6;

import "../BEP20Token.sol";

contract BytexCasinoToken is BEP20Token {
  constructor() public BEP20Token("Bytex Casino Token", "BYC", 18, 100 * 1e6 * 1e18) {
  }
}