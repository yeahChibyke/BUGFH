// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {BtcUsdcGasPriceFeeHook} from "../src/BtcUsdcGasPriceFeeHook.sol";

import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/// @notice Mainnet-fork tests for `BtcUsdcGasPriceFeeHook`.
/// @dev The suite reads the real Uniswap v4 WBTC/USDC pool to verify mainnet PoolManager access, then initializes a
/// separate fork-local dynamic-fee pool with this hook attached. Existing pools cannot have hooks retrofitted, so the
/// local pool is the executable test surface for fee overrides and moving-average updates.
contract BtcUsdcGasPriceFeeHookForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @dev Existing mainnet WBTC/USDC pool used only as a read check against the forked PoolManager.
    PoolId internal constant MAINNET_WBTC_USDC_POOL_ID =
        PoolId.wrap(0xb98437c7ba28c6590dd4e1cc46aa89eed181f97108e5b6221730d41347bc817f);

    /// @dev Base dynamic LP fee stored on the fork-local hooked pool. Uniswap v4 LP fees are expressed in pips.
    uint24 internal constant BASE_LP_FEE = 3_000;
    int128 internal constant LIQUIDITY_DELTA = 1e10;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    /// @dev Permission bits required by the production hook's `getHookPermissions`.
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG;
    /// @dev Clears the low 14 address bits so the test can OR in the exact hook permission flags.
    uint160 internal constant CLEAR_ALL_HOOK_PERMISSIONS_MASK = ~uint160(0) << 14;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    PoolSwapTest internal swapRouter;
    BtcUsdcGasPriceFeeHook internal hook;
    PoolKey internal key;

    event Swap(
        PoolId indexed poolId,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );

    receive() external payable {}

    function setUp() public {
        string memory rpcUrl = vm.envString("RPC_URL");
        uint256 forkBlockNumber = vm.envOr("FORK_BLOCK_NUMBER", uint256(0));

        if (forkBlockNumber == 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork(rpcUrl, forkBlockNumber);
        }

        manager = IPoolManager(POOL_MANAGER);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);

        // The constructor seeds the moving average, so use a deterministic initial gas price.
        vm.txGasPrice(100 gwei);
        address hookAddress =
            address(uint160(uint256(type(uint160).max) & CLEAR_ALL_HOOK_PERMISSIONS_MASK | HOOK_FLAGS));
        deployCodeTo(
            "BtcUsdcGasPriceFeeHook.sol:BtcUsdcGasPriceFeeHook",
            abi.encode(manager, Currency.wrap(WBTC), Currency.wrap(USDC)),
            hookAddress
        );
        hook = BtcUsdcGasPriceFeeHook(hookAddress);

        key = PoolKey({
            currency0: Currency.wrap(WBTC),
            currency1: Currency.wrap(USDC),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        manager.initialize(key, SQRT_PRICE_1_1);

        // Dynamic-fee updates must come from the hook address for this hooked pool.
        vm.prank(address(hook));
        manager.updateDynamicLPFee(key, BASE_LP_FEE);

        deal(WBTC, address(this), 10e8);
        deal(USDC, address(this), 10_000_000e6);

        IERC20(WBTC).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(USDC).approve(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(WBTC).approve(address(swapRouter), type(uint256).max);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);

        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: LIQUIDITY_DELTA, salt: 0}), ""
        );
    }

    function test_existingMainnetWbtcUsdcPoolIsReadable() public view {
        (uint160 sqrtPriceX96,,, uint24 lpFee) = manager.getSlot0(MAINNET_WBTC_USDC_POOL_ID);

        assertGt(sqrtPriceX96, 0);
        assertEq(lpFee, BASE_LP_FEE);
    }

    function test_currentFeeUsesPoolBaseFeeAndCurrentGasPrice() public {
        assertEq(hook.poolBaseFee(key), BASE_LP_FEE);

        vm.txGasPrice(150 gwei);
        assertEq(hook.currentFee(key), BASE_LP_FEE / 3);

        vm.txGasPrice(50 gwei);
        assertEq(hook.currentFee(key), BASE_LP_FEE * 2);

        vm.txGasPrice(100 gwei);
        assertEq(hook.currentFee(key), BASE_LP_FEE);
    }

    function test_swapUsesLowGasAdjustedFeeAndUpdatesMovingAverage() public {
        assertEq(hook.movingAverageGasPrice(), 100 gwei);
        assertEq(hook.movingAverageGasPriceCount(), 1);

        _swapAndAssertFee(50 gwei, BASE_LP_FEE * 2);

        assertEq(hook.movingAverageGasPrice(), 75 gwei);
        assertEq(hook.movingAverageGasPriceCount(), 2);
        assertEq(hook.poolBaseFee(key), BASE_LP_FEE);
    }

    function test_swapUsesNormalGasBaseFee() public {
        assertEq(hook.movingAverageGasPrice(), 100 gwei);
        assertEq(hook.movingAverageGasPriceCount(), 1);

        _swapAndAssertFee(100 gwei, BASE_LP_FEE);

        assertEq(hook.movingAverageGasPrice(), 100 gwei);
        assertEq(hook.movingAverageGasPriceCount(), 2);
        assertEq(hook.poolBaseFee(key), BASE_LP_FEE);
    }

    function test_swapUsesHighGasAdjustedFee() public {
        assertEq(hook.movingAverageGasPrice(), 100 gwei);
        assertEq(hook.movingAverageGasPriceCount(), 1);

        _swapAndAssertFee(150 gwei, BASE_LP_FEE / 3);

        assertEq(hook.movingAverageGasPrice(), 125 gwei);
        assertEq(hook.movingAverageGasPriceCount(), 2);
        assertEq(hook.poolBaseFee(key), BASE_LP_FEE);
    }

    function _swapAndAssertFee(uint256 gasPrice, uint24 expectedFee) internal returns (BalanceDelta delta) {
        vm.txGasPrice(gasPrice);

        // The PoolManager emits the actual LP fee used for the swap. Matching this event verifies the override path.
        vm.expectEmit(true, true, false, false, address(manager));
        emit Swap(key.toId(), address(swapRouter), 0, 0, 0, 0, 0, expectedFee);

        delta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertLt(delta.amount0(), 0);
        assertGt(delta.amount1(), 0);
    }
}
