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

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./../StrategyBase.sol";

import "../../../third_party/uniswap/IWETH.sol";
import "./pipelines/LinearPipeline.sol";
import "./pipes/UnwrappingPipe.sol";
import "./pipes/AaveWethPipe.sol";
import "./pipes/MaiCamWMaticPipe.sol";
import "./pipes/MaiStablecoinPipe.sol";
import "./pipes/BalVaultPipe.sol";

/// @title AAVE->MAI->BAL Multi Strategy
/// @author belbix, bogdoslav
contract AaveMaiBalStrategyBase is StrategyBase, LinearPipeline {
    using SafeERC20 for IERC20;

    /// @notice Strategy type for statistical purposes
    string public constant override STRATEGY_NAME = "AaveMaiBalStrategyBase";
    /// @notice Version of the contract
    /// @dev Should be incremented when contract changed
    string public constant VERSION = "1.0.0";
    /// @dev Placeholder, for non full buyback need to implement liquidation
    uint256 private constant _BUY_BACK_RATIO = 10000;

    /// @dev Assets should reflect underlying tokens for investing
    address[] private _assets;

    // cached total amount in underlying tokens, updated after each deposit, withdraw and hardwork
    uint256 private _totalAmount = 0;

    address public WMATIC;

    /// @notice Contract constructor
    constructor(
        address _controller,
        address _underlying,
        address _vault,
        address[] memory __rewardTokens,
        address _WMATIC
//        AaveWethPipeData memory aaveWethPipeData,
//        MaiCamWMaticPipeData memory maiCamWMaticPipeData,
//        MaiStablecoinPipeData memory maiStablecoinPipeData,
//        BalVaultPipeData memory balVaultPipeData
    ) StrategyBase(_controller, _underlying, _vault, __rewardTokens, _BUY_BACK_RATIO)
      LinearPipeline(_underlying)
    {
        WMATIC = _WMATIC;
        require(_underlying == WMATIC, "MS: underlying must be WMATIC");
        _rewardTokens = __rewardTokens;

        console.log('AaveMaiBalStrategyBase Initialized');
    }

  /*  /// @dev creates segment and initializes its context //TODO move this function to appropriate base file
    function initSegment(Pipe pipe, bytes memory context) internal returns (PipeSegment memory segment) {
        segment = PipeSegment(pipe, context);
        segment.context = segment.init(); //TODO
    }*/


/// @dev Stub function for Strategy Base implementation
    function rewardPoolBalance() public override view returns (uint256 bal) {
        return _totalAmount;
    }

    /// @dev Stub function for Strategy Base implementation
    function doHardWork() external onlyNotPausedInvesting override restricted {
        pumpIn(ERC20Balance(_underlyingToken), 0);
        liquidateReward();
        rebalanceAllPipes();
        claimFromAllPipes();
        _totalAmount = calculator.getTotalAmountOut(0);
    }

    /// @dev Stub function for Strategy Base implementation
    function depositToPool(uint256 underlyingAmount) internal override {
        pumpIn(underlyingAmount, 0);
        _totalAmount = calculator.getTotalAmountOut(0);
    }

    /// @dev Stub function for Strategy Base implementation
    function withdrawAndClaimFromPool(uint256 underlyingAmount) internal override {
        pumpOutSource(underlyingAmount, 0);
        _totalAmount = calculator.getTotalAmountOut(0);
    }

    /// @dev Stub function for Strategy Base implementation
    function emergencyWithdrawFromPool() internal override {
        pumpOut(getMostUnderlyingBalance(), 0);
    }

    /// @dev Stub function for Strategy Base implementation
    //slither-disable-next-line dead-code
    function liquidateReward() internal override {
        liquidateRewardDefault();
    }

    /// @dev Stub function for Strategy Base implementation
    function readyToClaim() external view override returns (uint256[] memory) {
        uint256[] memory toClaim = new uint256[](_rewardTokens.length); //TODO
        return toClaim;
    }

    /// @dev Stub function for Strategy Base implementation
    function poolTotalAmount() external pure override returns (uint256) {
        return 0;
    }

    function assets() external view override returns (address[] memory) {
        return _assets;
    }

    function platform() external pure override returns (Platform) {
        return Platform.AAVE_MAI_BAL;
    }

    /// @notice Controller can claim coins that are somehow transferred into the contract
    ///         Note that they cannot come in take away coins that are used and defined in the strategy itself
    /// @param recipient Recipient address
    /// @param recipient Token address
    /// @param recipient Token amount
    function salvageFromPipeline(address recipient, address token)
    external onlyController {
        salvageFromAllPipes(recipient, token); // transfers all amounts
    }

    receive() external payable {}

}
