// SPDX-License-Identifier: ISC
/**
* By using this software, you understand, acknowledge and accept that Tetu
* and/or the underlying software are provided “as is” and “as available”
* basis and without warranties or representations of any kind either expressed
* or implied. Any use of this open source software released under the ISC
* Internet Systems Consortium license is done at your own risk to the fullest
* extent permissible pursuant to applicable law any and all liability as well
* as all warranties, including any fitness for a particular purpose with respect
* to Tetu and/or the underlying software and the use thereof are disclaimed.
*/

pragma solidity 0.8.4;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../FoldingBase.sol";
import "../../../third_party/iron/CompleteRToken.sol";
import "../../../third_party/scream/IScreamController.sol";
import "../../../third_party/iron/IRMatic.sol";
import "../../../third_party/iron/IronPriceOracle.sol";
import "../../../third_party/IWmatic.sol";
import "../../interface/IScreamFoldStrategy.sol";
import "../../interface/IScreamFoldStrategy.sol";

import "hardhat/console.sol";



/// @title Abstract contract for Scream lending strategy implementation with folding functionality
/// @author OlegN
abstract contract ScreamFoldStrategyBase is FoldingBase, IScreamFoldStrategy {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  // ************ VARIABLES **********************
  /// @notice Strategy type for statistical purposes
  string public constant override STRATEGY_NAME = "ScreamFoldStrategyBase";
  /// @notice Version of the contract
  /// @dev Should be incremented when contract changed
  string public constant VERSION = "1.0.0";
  /// @dev Placeholder, for non full buyback need to implement liquidation
  uint256 private constant _BUY_BACK_RATIO = 10000;
  /// @dev SCREAM token address for reward price determination
  address public constant SCREAM_R_TOKEN = 0xe0654C8e6fd4D733349ac7E09f6f23DA256bF475; //todo not needed???
  address public constant W_MATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
  address public constant R_ETHER = 0xCa0F37f73174a28a64552D426590d3eD601ecCa1;

  /// @notice scToken address
  address public override scToken;
  /// @notice Scream Controller address
  address public override screamController;

  /// @notice Contract constructor using on strategy implementation
  /// @dev The implementation should check each parameter
  constructor(
    address _controller,
    address _underlying,
    address _vault,
    address[] memory __rewardTokens,
    address _scToken,
    address _screamController,
    uint256 _borrowTargetFactorNumerator,
    uint256 _collateralFactorNumerator
  ) FoldingBase(
    _controller,
    _underlying,
    _vault,
    __rewardTokens,
    _BUY_BACK_RATIO,
    _borrowTargetFactorNumerator,
    _collateralFactorNumerator
  ) {
    require(_scToken != address(0), "IFS: Zero address rToken");
    require(_screamController != address(0), "IFS: Zero address ironController");
    scToken = _scToken;
    screamController = _screamController;

    if (_isMatic()) {
      require(_underlyingToken == W_MATIC, "IFS: Only wmatic allowed");
    } else {
      address _lpt = CompleteRToken(scToken).underlying();
      require(_lpt == _underlyingToken, "IFS: Wrong underlying");
    }
  }

  /////////////////////////////////////////////
  ////////////BASIC STRATEGY FUNCTIONS/////////
  /////////////////////////////////////////////

  /// @notice Return approximately amount of reward tokens ready to claim in Iron Controller contract
  /// @dev Don't use it in any internal logic, only for statistical purposes
  /// @return Array with amounts ready to claim
  function readyToClaim() external view override returns (uint256[] memory) {
    uint256[] memory rewards = new uint256[](1);
    rewards[0] = IScreamController(screamController).rewardAccrued(address(this));
    return rewards;
  }

  /// @notice TVL of the underlying in the rToken contract
  /// @dev Only for statistic
  /// @return Pool TVL
  function poolTotalAmount() external view override returns (uint256) {
    return CompleteRToken(scToken).getCash()
    .add(CompleteRToken(scToken).totalBorrows())
    .sub(CompleteRToken(scToken).totalReserves());
  }

  /// @dev Do something useful with farmed rewards
  function liquidateReward() internal override {
    liquidateRewardDefault();
  }

  ///////////////////////////////////////////////////////////////////////////////////////
  ///////////// internal functions require specific implementation for each platforms ///
  ///////////////////////////////////////////////////////////////////////////////////////

  function _getInvestmentData() internal override returns (uint256 supplied, uint256 borrowed){
    supplied = CompleteRToken(scToken).balanceOfUnderlying(address(this));
    borrowed = CompleteRToken(scToken).borrowBalanceCurrent(address(this));
  }

  /// @dev Return true if we can gain profit with folding
  function _isFoldingProfitable() internal view override returns (bool) {
    // compare values per block per 1$
//    return rewardsRateNormalised() > foldCostRatePerToken();
    return true; //todo fix
  }

  /// @dev Claim distribution rewards
  function _claimReward() internal override {
    address[] memory markets = new address[](1);
    markets[0] = scToken;
    console.log("scToken %s", scToken);
    console.log("screamController %s", screamController);
    console.log("_rewardTokens[0] %s", _rewardTokens[0]);
    uint256 rewardBal1 = IERC20(_rewardTokens[0]).balanceOf(address(this));
    console.log("rewardBal1 %s", rewardBal1);


    IScreamController(screamController).claimComp(address(this), markets);

    uint256 rewardBal2 = IERC20(_rewardTokens[0]).balanceOf(address(this));
    console.log("rewardBal2 %s", rewardBal2);
  }

  function _supply(uint256 amount) internal override updateSupplyInTheEnd {
    amount = Math.min(IERC20(_underlyingToken).balanceOf(address(this)), amount);
    if (_isMatic()) {
      wmaticWithdraw(amount);
      IRMatic(scToken).mint{value : amount}();
    } else {
      IERC20(_underlyingToken).safeApprove(scToken, 0);
      IERC20(_underlyingToken).safeApprove(scToken, amount);
      require(CompleteRToken(scToken).mint(amount) == 0, "IFS: Supplying failed");
    }
  }

  function _borrow(uint256 amountUnderlying) internal override updateSupplyInTheEnd {
    // Borrow, check the balance for this contract's address
    require(CompleteRToken(scToken).borrow(amountUnderlying) == 0, "IFS: Borrow failed");
    if (_isMatic()) {
      IWmatic(W_MATIC).deposit{value : address(this).balance}();
    }
  }

  function _redeemUnderlying(uint256 amountUnderlying) internal override updateSupplyInTheEnd {
    // we can have a very little gap, it will slightly decrease ppfs and should be covered with reward liquidation process
    amountUnderlying = Math.min(amountUnderlying, CompleteRToken(scToken).balanceOfUnderlying(address(this)));
    if (amountUnderlying > 0) {
      uint256 redeemCode = 999;
      try CompleteRToken(scToken).redeemUnderlying(amountUnderlying) returns (uint256 code) {
        redeemCode = code;
      } catch{}
      if (redeemCode != 0) {
        // iron has verification function that can ruin tx with underlying, in this case redeem rToken will work
        (,,, uint256 exchangeRate) = CompleteRToken(scToken).getAccountSnapshot(address(this));
        uint256 rTokenRedeem = amountUnderlying * 1e18 / exchangeRate;
        if (rTokenRedeem > 0) {
          _redeemLoanToken(rTokenRedeem);
        }
      }
      if (_isMatic()) {
        IWmatic(W_MATIC).deposit{value : address(this).balance}();
      }
    }
  }

  function _redeemLoanToken(uint256 amount) internal updateSupplyInTheEnd {
    if (amount > 0) {
      require(CompleteRToken(scToken).redeem(amount) == 0, "IFS: Redeem failed");
    }
  }

  function _repay(uint256 amountUnderlying) internal override updateSupplyInTheEnd {
    if (amountUnderlying != 0) {
      if (_isMatic()) {
        wmaticWithdraw(amountUnderlying);
        IRMatic(scToken).repayBorrow{value : amountUnderlying}();
      } else {
        IERC20(_underlyingToken).safeApprove(scToken, 0);
        IERC20(_underlyingToken).safeApprove(scToken, amountUnderlying);
        require(CompleteRToken(scToken).repayBorrow(amountUnderlying) == 0, "IFS: Repay failed");
      }
    }
  }

  /// @dev Redeems the maximum amount of underlying. Either all of the balance or all of the available liquidity.
  function _redeemMaximumWithLoan() internal override updateSupplyInTheEnd {
    // amount of liquidity
    uint256 available = CompleteRToken(scToken).getCash();
    // amount we supplied
    uint256 supplied = CompleteRToken(scToken).balanceOfUnderlying(address(this));
    // amount we borrowed
    uint256 borrowed = CompleteRToken(scToken).borrowBalanceCurrent(address(this));
    uint256 balance = supplied.sub(borrowed);

    _redeemPartialWithLoan(Math.min(available, balance));

    // we have a little amount of supply after full exit
    // better to redeem rToken amount for avoid rounding issues
    (,uint256 rTokenBalance,,) = CompleteRToken(scToken).getAccountSnapshot(address(this));
    if (rTokenBalance > 0) {
      _redeemLoanToken(rTokenBalance);
    }
  }

  /////////////////////////////////////////////
  ////////////SPECIFIC INTERNAL FUNCTIONS//////
  /////////////////////////////////////////////

  function decimals() private view returns (uint8) {
    return CompleteRToken(scToken).decimals();
  }

  function underlyingDecimals() private view returns (uint8) {
    return IERC20Extended(_underlyingToken).decimals();
  }

  /// @dev Calculate expected rewards rate for reward token
  function rewardsRateNormalised() public view returns (uint256){
    CompleteRToken rt = CompleteRToken(scToken);

    // get reward per token for both - suppliers and borrowers
    uint256 rewardSpeed = IScreamController(screamController).rewardSpeeds(scToken);
    // using internal Iron Oracle the safest way
    uint256 rewardTokenPrice = rTokenUnderlyingPrice(SCREAM_R_TOKEN);
    // normalize reward speed to USD price
    uint256 rewardSpeedUsd = rewardSpeed * rewardTokenPrice / 1e18;

    // get total supply, cash and borrows, and normalize them to 18 decimals
    uint256 totalSupply = rt.totalSupply() * 1e18 / (10 ** decimals());
    uint256 totalBorrows = rt.totalBorrows() * 1e18 / (10 ** underlyingDecimals());

    // for avoiding revert for empty market
    if (totalSupply == 0 || totalBorrows == 0) {
      return 0;
    }

    // exchange rate between rToken and underlyingToken
    uint256 rTokenExchangeRate = rt.exchangeRateStored() * (10 ** decimals()) / (10 ** underlyingDecimals());

    // amount of reward tokens per block for 1 supplied underlyingToken
    uint256 rewardSpeedUsdPerSuppliedToken = rewardSpeedUsd * 1e18 / rTokenExchangeRate * 1e18 / totalSupply / 2;
    // amount of reward tokens per block for 1 borrowed underlyingToken
    uint256 rewardSpeedUsdPerBorrowedToken = rewardSpeedUsd * 1e18 / totalBorrows / 2;

    return rewardSpeedUsdPerSuppliedToken + rewardSpeedUsdPerBorrowedToken;
  }

  /// @dev Return a normalized to 18 decimal cost of folding
  function foldCostRatePerToken() public view returns (uint256) {
    CompleteRToken rt = CompleteRToken(scToken);

    // if for some reason supply rate higher than borrow we pay nothing for the borrows
    if (rt.supplyRatePerBlock() >= rt.borrowRatePerBlock()) {
      return 1;
    }
    uint256 foldRateCost = rt.borrowRatePerBlock() - rt.supplyRatePerBlock();
    uint256 _rTokenPrice = rTokenUnderlyingPrice(scToken);

    // let's calculate profit for 1 token
    return foldRateCost * _rTokenPrice / 1e18;
  }

  /// @dev Return rToken price from Iron Oracle solution. Can be used on-chain safely
  function rTokenUnderlyingPrice(address _rToken) public view returns (uint256){
    uint256 _rTokenPrice = IronPriceOracle(
      IScreamController(screamController).oracle()
    ).getUnderlyingPrice(_rToken);
    // normalize token price to 1e18
    if (underlyingDecimals() < 18) {
      _rTokenPrice = _rTokenPrice / (10 ** (18 - underlyingDecimals()));
    }
    return _rTokenPrice;
  }

  function wmaticWithdraw(uint256 amount) private {
    require(IERC20(W_MATIC).balanceOf(address(this)) >= amount, "IFS: Not enough wmatic");
    IWmatic(W_MATIC).withdraw(amount);
  }

  function _isMatic() internal view returns (bool) {
    return scToken == R_ETHER;
  }

}