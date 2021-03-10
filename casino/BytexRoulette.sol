// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.6.6;

import "../Ownable.sol";
import "../IBEP20.sol";
import "./RoulettePayout.sol";

contract BytexRoulette is Ownable {

  using RoulettePayout for *;

  struct Game {
    address payable player;
    uint bet;
    uint prize;
    bytes32 choiceHash;
    bytes32 signSeed;
    uint8 result;
    uint8 state;
    uint8 currency;
  }
    
  mapping (bytes32 => Game) public games;
  mapping (address => bool) public croupiers;
    
  // Minimum and maximum bets.
  uint public MIN_BET = 1e16; //0.01 BNB
  uint public MAX_BET = 1e18; // 1 BNB

  uint public BYX_MIN_BET = 20 * 1e18; // 20 BYX
  uint public BYX_MAX_BET = 2000 * 1e18; // 2000 BYX 

  uint public played;
  uint public winnings;
  uint public maxPayOutBNB = 10 * 1e18;
  uint public maxPayOutBYX = 20000 * 1e18;

  uint public bnbRewardRate = 10;
  uint public byxRewardRate = 1;
  uint public bnbBycRateOptimizer = 1;
  uint public byxBycRateOptimizer = 10;

  IBEP20 byxToken;
  IBEP20 bycToken;

  constructor(address _byxToken, address _bycToken) public {
      byxToken = IBEP20(_byxToken);
      bycToken = IBEP20(_bycToken);
  }
    
  event GameStarted(address indexed _user, bytes32 indexed _seed, uint256 _amount, uint8 currency);
  event GameResult(address indexed player, bytes32 indexed _seed, uint prize, uint rewardToken, uint8 result);

  modifier onlyCroupier() {
    require(croupiers[msg.sender], "Croupier: caller is not the croupier");
    _;
  }

  function addCroupier(address _croupier) public onlyOwner {
    croupiers[_croupier] = true;
  }

  function removeCroupier(address _croupier) public onlyOwner {
    croupiers[_croupier] = false;
  }

  function updateBetConf(uint _minBet, uint _maxBet, uint _maxPayOutBNB, 
    uint _byxMinBet, uint _byxMaxBet, uint _maxPayOutBYX) public onlyOwner {
    MIN_BET = _minBet;
    MAX_BET = _maxBet;
    maxPayOutBNB = _maxPayOutBNB;
    BYX_MIN_BET = _byxMinBet;
    BYX_MAX_BET = _byxMaxBet;
    maxPayOutBYX  = _maxPayOutBYX;
  }

  function updateBYCRate(uint _bnbRate, uint _bnbBycRateOptimizer, uint _byxRate, uint _byxBycRateOptimizer) public onlyOwner {
      bnbRewardRate = _bnbRate;
      bnbBycRateOptimizer = _bnbBycRateOptimizer;
      byxRewardRate = _byxRate;
      byxBycRateOptimizer = _byxBycRateOptimizer;
  }
  
  /**
   * @dev - to deposit BNB fund to the contract
   */
  receive() external payable {}
  
  /**
   * @dev - initiate game with BNB
   */
  function playGame(bytes32 _seed, uint[] memory _x, uint[] memory _y, bytes32 _choiceHash) public payable {
    require (msg.value >= MIN_BET && msg.value <= MAX_BET, "Amount out of range");
    _playGame(_seed, _x, _choiceHash, msg.value, 0);
    emit GameStarted(msg.sender, _seed, msg.value, 0);
  }

  /**
   * @dev - initiate game with BYX token
   */
  function playGameWithBYX(bytes32 _seed, uint[] memory _x, uint[] memory _y, bytes32 _choiceHash, uint _amount) public {
    require (_amount >= BYX_MIN_BET && _amount <= BYX_MAX_BET, "Amount out of range");
    _playGame(_seed, _x, _choiceHash, _amount, 1);
    byxToken.transferFrom(msg.sender, address(this), _amount);
    emit GameStarted(msg.sender, _seed, _amount, 1);
  }

  /**
   * @dev - validiate bets with total provide value and set state of the new game 
   * _seed - game identifier
   * _x - bets placed by user for current game
   * _y - position of bets for current game
   * _amount - total bet value
   * _currency - 0 or 1 indicating BNB or BYX 
   */
  function _playGame(bytes32 _seed, uint[] memory _x, bytes32 _choiceHash, uint _amount, uint8 _currency) internal {
    // Check that the game is in 'clean' state.
    Game storage game = games[_seed];
    require (game.player == address(0), "Invalid game state");

    uint totalVal = 0;
    for (uint i=0; i<_x.length; i++) {
        totalVal = add(totalVal, _x[i]);
    }
    require(_amount == totalVal, "Invalid Bets!");

    game.player = msg.sender;
    game.bet = _amount;
    game.choiceHash = _choiceHash;
    game.currency = _currency;
    game.state = 1;
  }
    
  /**
   * @dev - validate croupier signature and bets hash to ensure data integrity. Process the game 
   * and provision winnings and/or rewards token for the game
   */
  function confirm(bytes32 _seed, uint[] memory _x, uint[] memory _y, uint8 _v, bytes32 _r, bytes32 _s) public onlyCroupier {
    
    bytes memory prefix = "\x19Ethereum Signed Message:\n32";
    bytes32 signatureHash = keccak256(abi.encodePacked(prefix, _seed));
    address signedAddress = ecrecover(signatureHash, _v, _r, _s);
    require (croupiers[signedAddress], "ECDSA signature is not valid.");

    Game storage game = games[_seed];
    require(game.player != address(0) && game.state == 1, "Invalid game state");
    require(game.choiceHash == keccak256(abi.encodePacked(_x, _y)), "Bets mismatch");

    game.signSeed = _s;
    game.result = uint8(uint(_s) % uint(38));
    uint prize = RoulettePayout.getPayout(game.result, _x, _y);
    
    game.state = 2;
    
    if (prize > 0) {
      if (game.currency == 0) {
        game.prize = (prize > maxPayOutBNB) ? maxPayOutBNB : prize;
        safeBNBTransfer(game.player, game.prize);
      } else {
        game.prize = (prize > maxPayOutBYX) ? maxPayOutBYX : prize;
        safeTokenTransfer(game.player, game.prize);
      }
    }
    
    uint rewardToken;
    if (game.currency == 0) {
      rewardToken = safeRewardTokenTransfer(game.player, (game.bet/bnbBycRateOptimizer) * bnbRewardRate);
    } else {
      rewardToken = safeRewardTokenTransfer(game.player, (game.bet/byxBycRateOptimizer) * byxRewardRate);
    }

    played = played + 1;
    winnings = winnings + game.prize;

    emit GameResult(game.player, _seed, game.prize, rewardToken, game.result);
  }

  function choiceHash(uint[] memory _x, uint[] memory _y) public pure returns(bytes32) {
    return keccak256(abi.encodePacked(_x, _y));
  } 

  function stats() public view returns (uint gamesPlayed, uint totalWinnings){
    gamesPlayed = played;
    totalWinnings = winnings;
  }
  
  function collectProfit(address payable _to, uint _amount, uint _byxAmount) public onlyOwner {
    safeBNBTransfer(_to, _amount);
    safeTokenTransfer(_to, _byxAmount);
  }

  function emergencyWithdrawal(address payable _to) public onlyOwner {
    safeRewardTokenTransfer(_to, bycToken.balanceOf(address(this)));
    safeTokenTransfer(_to, byxToken.balanceOf(address(this)));
    safeBNBTransfer(_to, address(this).balance);
  }

  function safeBNBTransfer(address payable _to, uint _amount) internal {
    _amount = _amount < address(this).balance ? _amount : address(this).balance;
    _to.transfer(_amount);
  }

  function safeRewardTokenTransfer(address _to, uint _amount) internal returns(uint amount) {
    uint balance = bycToken.balanceOf(address(this));
    amount = (_amount > balance) ? balance : _amount;
    bycToken.transfer(_to, amount);
  }

  function safeTokenTransfer(address _to, uint _amount) internal {
    uint balance = byxToken.balanceOf(address(this));
    _amount = (_amount > balance) ? balance : _amount;
    byxToken.transfer(_to, _amount);
  }

  function add(uint a, uint b) internal pure returns (uint) {
    uint c = a + b;
    require(c >= a, "SafeMath: addition overflow");

    return c;
  }
    
}
