// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.6.6;

import "../Ownable.sol";
import "../IERC20.sol";
import "../SafeMath.sol";
import "./RoulettePayout.sol";

contract BytexRoulette is Ownable {

  using SafeMath for *;
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
  uint public MIN_BET = 1e15; //0.001 MATIC
  uint public MAX_BET = 1e18; // 1 MATIC

  uint public BYX_MIN_BET = 20 * 1e18; // 20 BYX
  uint public BYX_MAX_BET = 2000 * 1e18; // 2000 BYX 

  uint public played;
  uint public winnings;
  uint public maticInPlay;
  uint public byxInPlay;
  uint public maxPayOutMATIC = 10 * 1e18;
  uint public maxPayOutBYX = 20000 * 1e18;

  uint public maticRewardRate = 10;
  uint public byxRewardRate = 1;
  uint public maticBycRateOptimizer = 1;
  uint public byxBycRateOptimizer = 10;

  IERC20 byxToken;
  IERC20 bycToken;

  constructor(address _byxToken, address _bycToken) public {
      byxToken = IERC20(_byxToken);
      bycToken = IERC20(_bycToken);
  }
    
  event GameStarted(address indexed _user, bytes32 indexed _seed, uint256 _amount, uint8 currency);
  event GameResult(address indexed player, bytes32 indexed _seed, uint prize, uint rewardToken, uint8 result);

  modifier onlyCroupier() {
    require(croupiers[msg.sender], "Croupier: caller is not the croupier");
    _;
  }

  function addCroupier(address _croupier) external onlyOwner {
    croupiers[_croupier] = true;
  }

  function removeCroupier(address _croupier) external onlyOwner {
    croupiers[_croupier] = false;
  }

  function updateBetConf(uint _minBet, uint _maxBet, uint _maxPayOutMATIC, 
    uint _byxMinBet, uint _byxMaxBet, uint _maxPayOutBYX) external onlyOwner {
    MIN_BET = _minBet;
    MAX_BET = _maxBet;
    maxPayOutMATIC = _maxPayOutMATIC;
    BYX_MIN_BET = _byxMinBet;
    BYX_MAX_BET = _byxMaxBet;
    maxPayOutBYX  = _maxPayOutBYX;
  }

  function updateBYCRate(uint _maticRate, uint _maticBycRateOptimizer, uint _byxRate, uint _byxBycRateOptimizer) external onlyOwner {
      maticRewardRate = _maticRate;
      maticBycRateOptimizer = _maticBycRateOptimizer;
      byxRewardRate = _byxRate;
      byxBycRateOptimizer = _byxBycRateOptimizer;
  }
  
  /**
   * @dev - to deposit MATIC fund to the contract
   */
  receive() external payable {}
  
  /**
   * @dev - initiate game with MATIC
   */
  function playGame(bytes32 _seed, uint[] calldata _x, uint[] calldata _y, bytes32 _choiceHash) external payable {
    require (msg.value >= MIN_BET && msg.value <= MAX_BET, "Amount out of range");
    _playGame(_seed, _x, _choiceHash, msg.value, 0);
    maticInPlay = maticInPlay.add(msg.value);
    emit GameStarted(msg.sender, _seed, msg.value, 0);
  }

  /**
   * @dev - initiate game with BYX token
   */
  function playGameWithBYX(bytes32 _seed, uint[] calldata _x, uint[] calldata _y, bytes32 _choiceHash, uint _amount) external {
    require (_amount >= BYX_MIN_BET && _amount <= BYX_MAX_BET, "Amount out of range");
    _playGame(_seed, _x, _choiceHash, _amount, 1);
    byxToken.transferFrom(msg.sender, address(this), _amount);
    byxInPlay = byxInPlay.add(_amount);
    emit GameStarted(msg.sender, _seed, _amount, 1);
  }

  /**
   * @dev - validiate bets with total provide value and set state of the new game 
   * _seed - game identifier
   * _x - bets placed by user for current game
   * _y - position of bets for current game
   * _amount - total bet value
   * _currency - 0 or 1 indicating MATIC or BYX 
   */
  function _playGame(bytes32 _seed, uint[] memory _x, bytes32 _choiceHash, uint _amount, uint8 _currency) internal {
    // Check that the game is in 'clean' state.
    Game storage game = games[_seed];
    require (game.player == address(0), "Invalid game state");

    uint totalVal = 0;
    for (uint i=0; i<_x.length; i++) {
      totalVal = totalVal.add(_x[i]);
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
  function confirm(bytes32 _seed, uint[] calldata _x, uint[] calldata _y, uint8 _v, bytes32 _r, bytes32 _s) 
    external onlyCroupier {
    
    bytes memory prefix = "\x19Ethereum Signed Message:\n32";
    bytes32 signatureHash = keccak256(abi.encodePacked(prefix, _seed));
    require (owner() == ecrecover(signatureHash, _v, _r, _s), "ECDSA signature is not valid.");

    Game storage game = games[_seed];
    require(game.player != address(0) && game.state == 1, "Invalid game state");
    require(game.choiceHash == keccak256(abi.encodePacked(_x, _y)), "Bets mismatch");

    game.signSeed = _s;
    game.result = uint8(uint(_s) % uint(38));
    uint prize = RoulettePayout.getPayout(game.result, _x, _y);
    
    game.state = 2;
    
    if (prize > 0) {
      if (game.currency == 0) {
        game.prize = (prize > maxPayOutMATIC) ? maxPayOutMATIC : prize;
        safeMATICTransfer(game.player, game.prize);
      } else {
        game.prize = (prize > maxPayOutBYX) ? maxPayOutBYX : prize;
        safeTokenTransfer(game.player, game.prize);
      }
    }
    
    uint rewardToken;
    if (game.currency == 0) {
      maticInPlay = maticInPlay.sub(game.bet);
      rewardToken = safeRewardTokenTransfer(game.player, game.bet.mul(maticRewardRate).div(maticBycRateOptimizer));
    } else {
      byxInPlay = byxInPlay.sub(game.bet);
      rewardToken = safeRewardTokenTransfer(game.player, game.bet.mul(byxRewardRate).div(byxBycRateOptimizer));
    }

    played = played + 1;
    winnings = winnings + game.prize;

    emit GameResult(game.player, _seed, game.prize, rewardToken, game.result);
  }

  function choiceHash(uint[] calldata _x, uint[] calldata _y) external pure returns(bytes32) {
    return keccak256(abi.encodePacked(_x, _y));
  } 

  function stats() external view returns (uint gamesPlayed, uint totalWinnings){
    gamesPlayed = played;
    totalWinnings = winnings;
  }
  
  function collectProfit(address payable _to, uint _amount, uint _byxAmount) external onlyOwner {
    require(address(this).balance >= _amount.add(maticInPlay), "Cannot collect MATIC still in play");
    require(byxToken.balanceOf(address(this)) >= _byxAmount.add(byxInPlay), "Cannot collect BYX still in play");
    safeMATICTransfer(_to, _amount);
    safeTokenTransfer(_to, _byxAmount);
  }

  function safeMATICTransfer(address payable _to, uint _amount) internal {
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
    
}