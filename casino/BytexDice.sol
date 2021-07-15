pragma solidity ^0.6.6;

import "../Ownable.sol";
import "../IERC20.sol";
import "../SafeMath.sol";

contract BytexDice is Ownable {

  using SafeMath for uint256;

  struct Game {
    address payable player;
    uint256 bet;
    uint256 prize;
    uint256 choice;
    uint256 result;
    bytes32 signSeed;
    bool over;
    uint8 state;
    uint8 currency;
  }
    
  mapping (bytes32 => Game) public games;
  mapping (address => bool) public croupiers;
    
  // Minimum and maximum bets.
  uint256 public MIN_BET = 1e15; //0.001 MATIC
  uint256 public MAX_BET = 1e18; // 1 MATIC

  uint256 public BYX_MIN_BET = 20 * 1e18; // 20 BYX
  uint256 public BYX_MAX_BET = 2000 * 1e18; // 2000 BYX

  uint256 public MIN_CHOICE = 500;
  uint256 public MAX_CHOICE = 9500;
  uint256 public CHOICE_RANGE = 10000;

  uint256 public played;
  uint256 public winnings;

  uint256 public maticInPlay;
  uint256 public byxInPlay;
  uint256 public maxPayOutMATIC = 10 * 1e18;
  uint256 public maxPayOutBYX = 20000 * 1e18;

  uint256 public maticRewardRate = 10;
  uint256 public byxRewardRate = 1;
  uint256 public maticBycRateOptimizer = 1;
  uint256 public byxBycRateOptimizer = 10;
  uint8 public edge = 2;

  IERC20 byxToken;
  IERC20 bycToken;

  constructor(address _byxToken, address _bycToken) public {
    byxToken = IERC20(_byxToken);
    bycToken = IERC20(_bycToken);
  }
    
  event GameStarted(address indexed _user, bytes32 indexed _seed, bool over, uint256 _amount, uint8 currency);
  event GameResult(address indexed player, bytes32 indexed _seed, uint256 prize, uint256 rewardToken, uint256 result);

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

  function setBetRange(uint256 _min, uint256 _max) external onlyOwner {
    MIN_BET = _min;
    MAX_BET = _max;
  }

  function setByxBetRange(uint256 _min, uint256 _max) external onlyOwner {
    BYX_MIN_BET = _min;
    BYX_MAX_BET = _max;
  }

  function setChoiceRange(uint256 _min, uint256 _max, uint256 _range) external onlyOwner {
    MIN_CHOICE = _min;
    MAX_CHOICE = _max;
    CHOICE_RANGE = _range;
  }

  function setEdge(uint8 _edge) external onlyOwner {
    edge = _edge;
  }

  function updateBYCRate(uint256 _maticRate, uint256 _maticBycRateOp, uint256 _byxRate, uint256 _byxBycRateOp) external onlyOwner {
    maticRewardRate = _maticRate;
    maticBycRateOptimizer = _maticBycRateOp;
    byxRewardRate = _byxRate;
    byxBycRateOptimizer = _byxBycRateOp;
  }

  /**
   * @dev - to deposit MATIC fund to the contract
   */
  receive() external payable {}

  function playGame(bytes32 _seed, uint256 _choice, bool _over) external payable {
    require (msg.value >= MIN_BET && msg.value <= MAX_BET, "Amount out of range");
    _playGame(_seed, _choice, _over, msg.value, 0);
    maticInPlay = maticInPlay.add(msg.value);
    emit GameStarted(msg.sender, _seed, _over, msg.value, 0);
  }

  function playGameWithBYX(bytes32 _seed, uint256 _choice, bool _over, uint256 _amount) external {
    require (_amount >= BYX_MIN_BET && _amount <= BYX_MAX_BET, "Amount out of range");
    _playGame(_seed, _choice, _over, _amount, 1);
    byxToken.transferFrom(msg.sender, address(this), _amount);
    byxInPlay = byxInPlay.add(_amount);
    emit GameStarted(msg.sender, _seed, _over, _amount, 1);
  }

  function _playGame(bytes32 _seed, uint256 _choice, bool _over, uint256 _amount, uint8 _currency) internal {
    require (_choice >= MIN_CHOICE && _choice <= MAX_CHOICE, "Choice out of range");

    // Check that the game is in 'clean' state.
    Game storage game = games[_seed];
    require (game.player == address(0), "Invalid game state");

    game.player = msg.sender;
    game.bet = _amount;
    game.choice = _choice;
    game.over = _over;
    game.currency = _currency;
    game.state = 1;
  }

  function confirm(bytes32 _seed, uint8 _v, bytes32 _r, bytes32 _s) external onlyCroupier {
    bytes memory prefix = "\x19Ethereum Signed Message:\n32";
    bytes32 signatureHash = keccak256(abi.encodePacked(prefix, _seed));
    require (owner() == ecrecover(signatureHash, _v, _r, _s), "ECDSA signature is not valid.");

    Game storage game = games[_seed];
    require(game.player != address(0) && game.state == 1, "Invalid game state");

    game.signSeed = _s;
    game.result = uint256(_s).mod(uint256(CHOICE_RANGE));
    game.state = 2;

    // Check if player wins, then calcuate the prize and send BNB or BYX token
    if ((game.over && game.result > game.choice) || (!game.over && game.result < game.choice)) {
      uint256 houseEdge = game.bet * edge / 100;
      game.prize = (game.bet - houseEdge) * CHOICE_RANGE / game.choice;
      if (game.currency == 0) {
        safeMATICTransfer(game.player, game.prize);
      } else {
        safeTokenTransfer(game.player, game.prize);
      }
    } else {
      game.prize = 0;
    }

    uint256 rewardSent;
    // Send mined casino tokens based on wager currency rate
    if (game.currency == 0) {
      maticInPlay = maticInPlay.sub(game.bet);
      rewardSent = safeRewardTokenTransfer(game.player, game.bet.mul(maticRewardRate).div(maticBycRateOptimizer));
    } else {
      byxInPlay = byxInPlay.sub(game.bet);
      rewardSent = safeRewardTokenTransfer(game.player, game.bet.mul(byxRewardRate).div(byxBycRateOptimizer));
    }

    played = played + 1;
    winnings = winnings + game.prize;

    emit GameResult(game.player, _seed, game.prize, rewardSent, game.result);
  }

  function stats() external view returns (uint gamesPlayed, uint totalWinnings){
    gamesPlayed = played;
    totalWinnings = winnings;
  }
  
  function collectProfit(address payable _to, uint256 _amount, uint256 _byxAmount) external onlyOwner {
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