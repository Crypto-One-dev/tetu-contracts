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
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../FoldingBase.sol";

import "../../interface/ISmartVault.sol";
import "../../../third_party/IWmatic.sol";
import "../../../third_party/aave/IAToken.sol";
import "../../interface/IAveFoldStrategy.sol";
import "../../../third_party/aave/ILendingPool.sol";

import "../../../third_party/aave/IAaveIncentivesController.sol";
import "../../../third_party/aave/IProtocolDataProvider.sol";
import "../../../third_party/aave/DataTypes.sol";
import "../../../third_party/aave/IPriceOracle.sol";


/// @title Abstract contract for Aave lending strategy implementation with folding functionality
/// @author JasperS13
/// @author belbix
/// @author olegn
abstract contract AaveFoldStrategyBase is FoldingBase, IAveFoldStrategy {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  // ************ VARIABLES **********************
  /// @dev precision for the folding profitability calculation
  uint8 private constant _PRECISION = 18;
  /// @dev precision for the RAY values e.g currentLiquidityRate value
  uint8 private constant _RAY_PRECISION = 27;
  /// @dev approximate number of seconds per year
  uint256 private constant _SECONDS_PER_YEAR = 365 * 24 * 60 * 60;
  /// @dev approximate 1 month - default time period for profitability forecast
  uint256 private constant _PROFITABILITY_PERIOD = 30 days;
  /// @notice Strategy type for statistical purposes
  string public constant override STRATEGY_NAME = "AaveFoldStrategyBase";
  /// @notice Version of the contract
  /// @dev Should be incremented when contract changed
  string public constant VERSION = "1.0.0";
  /// @dev Placeholder, for non full buyback need to implement liquidation
  uint256 private constant _BUY_BACK_RATIO = 10000;

  // todo move to attributes
  address public constant WETH = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
  address public constant W_MATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
  address public constant AMWMATIC = 0x8dF3aad3a84da6b69A4DA8aeC3eA40d9091B2Ac4;

  address public constant AAVE_LENDING_POOL = 0x8dFf5E27EA6b7AC08EbFdf9eB090F32ee9a30fcf;
  address public constant AAVE_CONTROLLER = 0x357D51124f59836DeD84c8a1730D72B749d8BC23;
  address public constant AAVE_DATA_PROVIDER = 0x7551b5D2763519d4e37e8B81929D336De671d46d;
  address public constant AAVE_LENDING_POOL_ADDRESSES_PROVIDER = 0xd05e3E715d945B59290df0ae8eF85c1BdB684744;

  ILendingPool lPool = ILendingPool(AAVE_LENDING_POOL);
  IAaveIncentivesController aaveController = IAaveIncentivesController(AAVE_CONTROLLER);
  IProtocolDataProvider dataProvider = IProtocolDataProvider(AAVE_DATA_PROVIDER);
  ILendingPoolAddressesProvider lendingPoolAddressesProvider = ILendingPoolAddressesProvider(AAVE_LENDING_POOL_ADDRESSES_PROVIDER);

  address public override aToken;
  address public override dToken;

  /// @notice Contract constructor using on strategy implementation
  constructor(
    address _controller,
    address _underlying,
    address _vault,
    address[] memory __rewardTokens,
    uint256 _borrowTargetFactorNumerator,
    uint256 _collateralFactorNumerator,
    uint256 _factorDenominator
  ) FoldingBase(
    _controller,
    _underlying,
    _vault,
    __rewardTokens,
    _BUY_BACK_RATIO,
    _borrowTargetFactorNumerator,
    _collateralFactorNumerator,
    _factorDenominator
  ) {
    (aToken,,dToken) = dataProvider.getReserveTokensAddresses(_underlying);
    address _lpt = IAToken(aToken).UNDERLYING_ASSET_ADDRESS();
    require(_lpt == _underlyingToken, "AFS: Wrong underlying");
  }

  /////////////////////////////////////////////
  ////////////BASIC STRATEGY FUNCTIONS/////////
  /////////////////////////////////////////////

  /// @notice Return approximately amount of reward tokens ready to claim in AAVE Lending pool
  /// @dev Don't use it in any internal logic, only for statistical purposes
  /// @return Array with amounts ready to claim
  function readyToClaim() external view override returns (uint256[] memory) {
    uint256[] memory rewards = new uint256[](1);
    rewards[0] = aaveController.getUserUnclaimedRewards(address(this));
    return rewards;
  }

  /// @notice TVL of the underlying in the aToken contract
  /// @dev Only for statistic
  /// @return Pool TVL
  function poolTotalAmount() external view override returns (uint256) {
    return IERC20(_underlyingToken).balanceOf(aToken);
  }

  /// @dev Do something useful with farmed rewards
  function liquidateReward() internal override {
    liquidateRewardDefault();
  }

  ///////////////////////////////////////////////////////////////////////////////////////
  ///////////// internal functions require specific implementation for each platforms ///
  ///////////////////////////////////////////////////////////////////////////////////////

  function _getInvestmentData() internal view override returns (uint256, uint256) {
    (uint256 suppliedUnderlying,,uint256 borrowedUnderlying,,,,,,) = dataProvider.getUserReserveData(_underlyingToken, address(this));
    return (suppliedUnderlying, borrowedUnderlying);
  }

  /// @dev Return true if we can gain profit with folding
  function _isFoldingProfitable() internal view override returns (bool) {
    (uint256 supplyRewardsInWethPT,
    uint256 borrowRewardsInWethPT,
    uint256 supplyUnderlyingProfitInWethPT,
    uint256 debtUnderlyingCostInWethPT) = normTotalRewardPredictionInWeth(_PROFITABILITY_PERIOD);

    uint256 foldingProfitPerToken = supplyRewardsInWethPT + borrowRewardsInWethPT + supplyUnderlyingProfitInWethPT;
    return foldingProfitPerToken > debtUnderlyingCostInWethPT;
  }

  /// @dev Claim distribution rewards
  function _claimReward() internal override {
    address[] memory assets = new address[](2);
    assets[0] = aToken;
    assets[1] = dToken;
    aaveController.claimRewards(assets, type(uint256).max, address(this));
  }

  //////////// require update balance in the end

  function _supply(uint256 amount) internal override updateSupplyInTheEnd {
    amount = Math.min(IERC20(_underlyingToken).balanceOf(address(this)), amount);
    IERC20(_underlyingToken).safeApprove(AAVE_LENDING_POOL, 0);
    IERC20(_underlyingToken).safeApprove(AAVE_LENDING_POOL, amount);
    lPool.deposit(_underlyingToken, amount, address(this), 0);
  }

  /// @dev Borrows against the collateral
  function _borrow(uint256 amountUnderlying) internal override updateSupplyInTheEnd {
    // Borrow, check the balance for this contract's address
    lPool.borrow(_underlyingToken, amountUnderlying, 2, 0, address(this));
  }

  /// @dev Redeem liquidity in underlying
  function _redeemUnderlying(uint256 amountUnderlying) internal override updateSupplyInTheEnd {
    // we can have a very little gap, it will slightly decrease ppfs and should be covered with reward liquidation process
    (uint256 suppliedUnderlying,) = _getInvestmentData();
    amountUnderlying = Math.min(amountUnderlying, suppliedUnderlying);
    if (amountUnderlying > 0) {
      lPool.withdraw(_underlyingToken, amountUnderlying, address(this));
    }
  }

  /// @dev Redeem liquidity in aToken
  function _redeemLoanToken(uint256 amount) internal override updateSupplyInTheEnd {
    if (amount > 0) {
      lPool.withdraw(_underlyingToken, amount, address(this));
      uint256 aTokenBalance = IERC20(aToken).balanceOf(address(this));
      require(aTokenBalance == 0, "AFS: Redeem failed");
    }
  }

  /// @dev Repay a loan
  function _repay(uint256 amountUnderlying) internal override updateSupplyInTheEnd {
    if (amountUnderlying != 0) {
      IERC20(_underlyingToken).safeApprove(AAVE_LENDING_POOL, 0);
      IERC20(_underlyingToken).safeApprove(AAVE_LENDING_POOL, amountUnderlying);
      lPool.repay(_underlyingToken, amountUnderlying, 2, address(this));
    }
  }

  /// @dev Redeems the maximum amount of underlying.
  ///      Either all of the balance or all of the available liquidity.
  function _redeemMaximumWithLoan() internal override updateSupplyInTheEnd {
    // amount of liquidity
    (uint256 availableLiquidity,,,,,,,,,) = dataProvider.getReserveData(_underlyingToken);
    (uint256 supplied, uint256 borrowed) = _getInvestmentData();
    uint256 balance = supplied.sub(borrowed);
    _redeemPartialWithLoan(Math.min(availableLiquidity, balance));

    // we have a little amount of supply after full exit
    // better to redeem rToken amount for avoid rounding issues
    (supplied, borrowed) = _getInvestmentData();
    uint256 aTokenBalance = IERC20(aToken).balanceOf(address(this));

    if (aTokenBalance > 0) {
      _redeemLoanToken(aTokenBalance);
    }
  }

  /////////////////////////////////////////////
  ////////////SPECIFIC INTERNAL FUNCTIONS//////
  /////////////////////////////////////////////


  /// @notice return WMATIC reward forecast for aave token (supply or debt)
  /// @dev Don't use it in any internal logic, only for statistical purposes
  /// @param numberOfBlocks time period for the forecast
  /// @param token address (supply or debt)
  /// @return forecasted amount of WMATIC tokens
  function rewardPrediction(uint256 numberOfBlocks, address token) public view returns (uint256){
    (uint256 emissionPerSecond,,) = aaveController.assets(token);
    (uint256 stakedByUserScaled, uint256 totalStakedScaled) = IScaledBalanceToken(token).getScaledUserBalanceAndSupply(address(this));
    uint256 rewards = emissionPerSecond.mul(numberOfBlocks).mul(10 ** uint256(_PRECISION)).div(totalStakedScaled).mul(stakedByUserScaled).div(10 ** uint256(_PRECISION));
    return rewards;
  }

  /// @notice return underlying reward forecast for aave supply token
  /// @dev Don't use it in any internal logic, only for statistical purposes
  /// @param numberOfBlocks time period for the forecast
  /// @param token address (supply)
  /// @param currentLiquidityRate from the AAVE dataProvider
  /// @return forecasted amount of underlying tokens
  function rewardUnderlyingPrediction(
    uint256 numberOfBlocks,
    address token,
    uint256 currentLiquidityRate
  ) public view returns (uint256){
    uint256 underlyingPerSecond = currentLiquidityRate.div(_SECONDS_PER_YEAR);
    uint256 underlyingBalance = IERC20(token).balanceOf(address(this));
    uint256 predictedUnderlyingEarned = underlyingPerSecond.mul(numberOfBlocks);
    return predictedUnderlyingEarned.mul(underlyingBalance).div(10 ** uint256(_RAY_PRECISION));
  }

  /// @notice returns forecast of the debt cost in the underlying tokens
  /// @dev Don't use it in any internal logic, only for statistical purposes
  /// @param numberOfBlocks time period for the forecast
  /// @param token address (debt)
  /// @return forecasted amount of underlying tokens which needs to be payed as debt interest
  function debtCostPrediction(
    uint256 numberOfBlocks,
    address token,
    uint256 currentVariableBorrowRate
  ) public view returns (uint256){
    uint256 debtUnderlyingPerSecond = currentVariableBorrowRate.div(_SECONDS_PER_YEAR);
    uint256 debtBalance = IERC20(token).balanceOf(address(this));
    uint256 predictedDebtCost = debtUnderlyingPerSecond.mul(numberOfBlocks);
    return predictedDebtCost.mul(debtBalance).div(10 ** uint256(_RAY_PRECISION));
  }

  /// @notice returns forecast of all rewards (WMATIC and underlying) for the given period of time
  /// @dev Don't use it in any internal logic, only for statistical purposes
  /// @param numberOfBlocks time period for the forecast
  function totalRewardPrediction(uint256 numberOfBlocks) public view returns (
    uint256 supplyRewards,
    uint256 borrowRewards,
    uint256 supplyUnderlyingProfit,
    uint256 debtUnderlyingCost
  ){
    (address aTokenAddress,,address variableDebtTokenAddress) = dataProvider.getReserveTokensAddresses(_underlyingToken);

    supplyRewards = rewardPrediction(numberOfBlocks, aTokenAddress);
    borrowRewards = rewardPrediction(numberOfBlocks, variableDebtTokenAddress);

    DataTypes.ReserveData memory rd = lPool.getReserveData(_underlyingToken);
    supplyUnderlyingProfit = rewardUnderlyingPrediction(numberOfBlocks, aTokenAddress, rd.currentLiquidityRate);
    debtUnderlyingCost = debtCostPrediction(numberOfBlocks, variableDebtTokenAddress, rd.currentVariableBorrowRate);

    return (supplyRewards, borrowRewards, supplyUnderlyingProfit, debtUnderlyingCost);
  }
  /// @notice returns forecast of all rewards (WMATIC and underlying)
  ///         for the given period of time in WETH token using AAVE price oracle
  /// @dev Don't use it in any internal logic, only for statistical purposes
  /// @param numberOfBlocks time period for the forecast
  function totalRewardPredictionInWeth(uint256 numberOfBlocks) public view returns (
    uint256 supplyRewardsInWeth,
    uint256 borrowRewardsInWeth,
    uint256 supplyUnderlyingProfitInWeth,
    uint256 debtUnderlyingCostInWeth
  ){
    IPriceOracle priceOracle = IPriceOracle(lendingPoolAddressesProvider.getPriceOracle());
    uint256 underlyingInWeth = priceOracle.getAssetPrice(_underlyingToken);
    uint256 rewardInWeth = priceOracle.getAssetPrice(_rewardTokens[0]);
    uint256 wethDecimals = (ERC20(WETH)).decimals();

    (uint256 supplyRewards, uint256 borrowRewards, uint256 supplyUnderlyingProfit, uint256 debtUnderlyingCost) = totalRewardPrediction(numberOfBlocks);

    supplyRewardsInWeth = supplyRewards.mul(rewardInWeth).div(10 ** wethDecimals);
    borrowRewardsInWeth = borrowRewards.mul(rewardInWeth).div(10 ** wethDecimals);

    supplyUnderlyingProfitInWeth = supplyUnderlyingProfit.mul(underlyingInWeth).div(10 ** wethDecimals);
    debtUnderlyingCostInWeth = debtUnderlyingCost.mul(underlyingInWeth).div(10 ** wethDecimals);
  }
  /// @notice returns normalized (per invested underlying token) forecast of all rewards (WMATIC and underlying)
  ///         for the given period of time in WETH token using AAVE price oracle .
  /// @dev Don't use it in any internal logic, only for statistical purposes
  /// @param numberOfBlocks time period for the forecast
  function normTotalRewardPredictionInWeth(uint256 numberOfBlocks) public view returns (
    uint256 supplyRewardsInWethPT,
    uint256 borrowRewardsInWethPT,
    uint256 supplyUnderlyingProfitInWethPT,
    uint256 debtUnderlyingCostInWethPT
  ){
    uint256 supplyBalance = IERC20(aToken).balanceOf(address(this));
    uint256 debtBalance = IERC20(dToken).balanceOf(address(this));

    (uint256 supplyRewardsInWeth,
    uint256 borrowRewardsInWeth,
    uint256 supplyUnderlyingProfitInWeth,
    uint256 debtUnderlyingCostInWeth) = totalRewardPredictionInWeth(numberOfBlocks);

    supplyRewardsInWethPT = supplyRewardsInWeth.mul(10 ** uint256(_PRECISION)).div(supplyBalance);
    supplyUnderlyingProfitInWethPT = supplyUnderlyingProfitInWeth.mul(10 ** uint256(_PRECISION)).div(supplyBalance);

    borrowRewardsInWethPT = 0;
    debtUnderlyingCostInWethPT = 0;
    if (debtBalance > 0) {
      borrowRewardsInWethPT = borrowRewardsInWeth.mul(10 ** uint256(_PRECISION)).div(debtBalance);
      debtUnderlyingCostInWethPT = debtUnderlyingCostInWeth.mul(10 ** uint256(_PRECISION)).div(debtBalance);
    }
  }

  /// @notice number of decimals for the supply token
  function supplyTokenDecimals() private view returns (uint8) {
    return ERC20(aToken).decimals();
  }

  /// @notice number of decimals for the debt token
  function debtTokenDecimals() private view returns (uint8) {
    return ERC20(dToken).decimals();
  }

  /// @notice number of decimals for the underlying token
  function underlyingDecimals() private view returns (uint8) {
    return ERC20(_underlyingToken).decimals();
  }


}