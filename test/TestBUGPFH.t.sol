// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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

/// @dev Shared addresses and hook-flag helpers for both test suites.
abstract contract HookTestBase is Test {
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @dev Permission bits required by the production hook's `getHookPermissions`.
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG;
    /// @dev Clears the low 14 address bits so a test can OR in the exact hook permission flags.
    uint160 internal constant CLEAR_ALL_HOOK_PERMISSIONS_MASK = ~uint160(0) << 14;

    /// @dev Returns an address whose low 14 bits carry exactly `HOOK_FLAGS`, with `seed` placed in the high bits so
    /// multiple distinct hooks can be deployed in one test without colliding.
    function _hookAddress(uint96 seed) internal pure returns (address) {
        return address((uint160(seed) << 24) | HOOK_FLAGS);
    }

    /// @dev Deploys the hook at a flag-valid address using `deployCodeTo`, returning the typed handle.
    function _deployHook(uint96 seed, IPoolManager _manager, Currency _btc, Currency _usdc)
        internal
        returns (BtcUsdcGasPriceFeeHook)
    {
        address addr = _hookAddress(seed);
        deployCodeTo("BtcUsdcGasPriceFeeHook.sol:BtcUsdcGasPriceFeeHook", abi.encode(_manager, _btc, _usdc), addr);
        return BtcUsdcGasPriceFeeHook(addr);
    }
}

/// @notice Fork-free unit tests for `BtcUsdcGasPriceFeeHook` covering construction, configuration, permissions, and
/// input validation. These paths never read pool state, so no mainnet fork is required and the suite stays fast.
contract BtcUsdcGasPriceFeeHookUnitTest is HookTestBase {
    /// @dev A non-existent PoolManager: construction and validation paths under test never call into it.
    IPoolManager internal constant DUMMY_MANAGER = IPoolManager(address(0xDEAD));

    function _wbtcUsdcKey(uint24 fee) internal pure returns (PoolKey memory) {
        // WBTC sorts below USDC, so currency0 == WBTC.
        return PoolKey({
            currency0: Currency.wrap(WBTC),
            currency1: Currency.wrap(USDC),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function test_constructorRevertsOnIdenticalCurrencies() public {
        vm.expectRevert(BtcUsdcGasPriceFeeHook.BUGH__IdenticalCurrencies.selector);
        _deployHook(1, DUMMY_MANAGER, Currency.wrap(WBTC), Currency.wrap(WBTC));
    }

    /// @dev The constructor must place currencies in v4 sorted order regardless of the argument order it receives.
    function test_constructorSortsCurrenciesIndependentOfArgumentOrder() public {
        // BTC passed first.
        BtcUsdcGasPriceFeeHook a = _deployHook(2, DUMMY_MANAGER, Currency.wrap(WBTC), Currency.wrap(USDC));
        // USDC passed first; sorting must still produce the same pool currencies.
        BtcUsdcGasPriceFeeHook b = _deployHook(3, DUMMY_MANAGER, Currency.wrap(USDC), Currency.wrap(WBTC));

        // Configured roles follow the constructor arguments.
        assertEq(Currency.unwrap(a.btcCurrency()), WBTC);
        assertEq(Currency.unwrap(a.usdcCurrency()), USDC);
        assertEq(Currency.unwrap(b.btcCurrency()), USDC);
        assertEq(Currency.unwrap(b.usdcCurrency()), WBTC);

        // Pool currencies are sorted (WBTC < USDC) and identical for both regardless of argument order.
        assertEq(Currency.unwrap(a.poolCurrency0()), WBTC);
        assertEq(Currency.unwrap(a.poolCurrency1()), USDC);
        assertEq(Currency.unwrap(b.poolCurrency0()), WBTC);
        assertEq(Currency.unwrap(b.poolCurrency1()), USDC);
    }

    /// @dev The constructor seeds the moving average from the deployment transaction gas price as a single observation.
    function test_constructorSeedsMovingAverageFromDeploymentGasPrice() public {
        vm.txGasPrice(73 gwei);
        BtcUsdcGasPriceFeeHook h = _deployHook(4, DUMMY_MANAGER, Currency.wrap(WBTC), Currency.wrap(USDC));

        assertEq(h.movingAverageGasPrice(), 73 gwei);
        assertEq(h.movingAverageGasPriceCount(), 1);
    }

    /// @dev The deployed permission bits must match exactly what `getHookPermissions` declares; nothing more.
    function test_getHookPermissionsDeclaresOnlyTheExpectedCallbacks() public {
        BtcUsdcGasPriceFeeHook h = _deployHook(5, DUMMY_MANAGER, Currency.wrap(WBTC), Currency.wrap(USDC));
        Hooks.Permissions memory p = h.getHookPermissions();

        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);

        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    function test_poolBaseFeeRevertsOnUnsupportedPool() public {
        BtcUsdcGasPriceFeeHook h = _deployHook(6, DUMMY_MANAGER, Currency.wrap(WBTC), Currency.wrap(USDC));
        PoolKey memory wrong = _wbtcUsdcKey(LPFeeLibrary.DYNAMIC_FEE_FLAG);
        wrong.currency1 = Currency.wrap(address(0xBEEF)); // not the configured USDC

        vm.expectRevert(BtcUsdcGasPriceFeeHook.BUGH__UnsupportedPool.selector);
        h.poolBaseFee(wrong);
    }

    function test_poolBaseFeeRevertsOnStaticFeePool() public {
        BtcUsdcGasPriceFeeHook h = _deployHook(7, DUMMY_MANAGER, Currency.wrap(WBTC), Currency.wrap(USDC));

        vm.expectRevert(BtcUsdcGasPriceFeeHook.BUGH__MustUseDynamicFee.selector);
        h.poolBaseFee(_wbtcUsdcKey(3_000)); // static fee, not the dynamic-fee flag
    }

    function test_currentFeeRevertsOnUnsupportedPool() public {
        BtcUsdcGasPriceFeeHook h = _deployHook(8, DUMMY_MANAGER, Currency.wrap(WBTC), Currency.wrap(USDC));
        PoolKey memory wrong = _wbtcUsdcKey(LPFeeLibrary.DYNAMIC_FEE_FLAG);
        wrong.currency0 = Currency.wrap(address(0xBEEF)); // not the configured WBTC

        vm.expectRevert(BtcUsdcGasPriceFeeHook.BUGH__UnsupportedPool.selector);
        h.currentFee(wrong);
    }

    function test_currentFeeRevertsOnStaticFeePool() public {
        BtcUsdcGasPriceFeeHook h = _deployHook(9, DUMMY_MANAGER, Currency.wrap(WBTC), Currency.wrap(USDC));

        vm.expectRevert(BtcUsdcGasPriceFeeHook.BUGH__MustUseDynamicFee.selector);
        h.currentFee(_wbtcUsdcKey(3_000));
    }

    /// @dev `beforeInitialize` is the on-chain gatekeeper; it must reject a static-fee pool when called by the manager.
    function test_beforeInitializeRevertsOnStaticFeePool() public {
        BtcUsdcGasPriceFeeHook h = _deployHook(10, DUMMY_MANAGER, Currency.wrap(WBTC), Currency.wrap(USDC));

        vm.prank(address(DUMMY_MANAGER));
        vm.expectRevert(BtcUsdcGasPriceFeeHook.BUGH__MustUseDynamicFee.selector);
        h.beforeInitialize(address(this), _wbtcUsdcKey(3_000), 0);
    }

    /// @dev `beforeInitialize` must reject a pool whose currencies are not the configured pair.
    function test_beforeInitializeRevertsOnUnsupportedPool() public {
        BtcUsdcGasPriceFeeHook h = _deployHook(11, DUMMY_MANAGER, Currency.wrap(WBTC), Currency.wrap(USDC));
        PoolKey memory wrong = _wbtcUsdcKey(LPFeeLibrary.DYNAMIC_FEE_FLAG);
        wrong.currency0 = Currency.wrap(address(0xBEEF));

        vm.prank(address(DUMMY_MANAGER));
        vm.expectRevert(BtcUsdcGasPriceFeeHook.BUGH__UnsupportedPool.selector);
        h.beforeInitialize(address(this), wrong, 0);
    }
}

/// @notice Mainnet-fork integration tests for `BtcUsdcGasPriceFeeHook`.
/// @dev The suite reads the real Uniswap v4 WBTC/USDC pool to verify mainnet PoolManager access, then initializes a
/// separate fork-local dynamic-fee pool with this hook attached. Existing pools cannot have hooks retrofitted, so the
/// local pool is the executable test surface for fee overrides and moving-average updates.
contract BtcUsdcGasPriceFeeHookForkTest is HookTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    /// @dev Existing mainnet WBTC/USDC pool used only as a read check against the forked PoolManager.
    PoolId internal constant MAINNET_WBTC_USDC_POOL_ID =
        PoolId.wrap(0xb98437c7ba28c6590dd4e1cc46aa89eed181f97108e5b6221730d41347bc817f);

    /// @dev `keccak256` of the PoolManager `Swap` event signature (PoolId is encoded as its `bytes32` underlying type).
    bytes32 internal constant SWAP_EVENT_SIG =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    /// @dev Base dynamic LP fee stored on the fork-local hooked pool. Uniswap v4 LP fees are expressed in pips.
    uint24 internal constant BASE_LP_FEE = 3_000;
    int128 internal constant LIQUIDITY_DELTA = 1e10;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint128 internal constant INITIAL_GAS_PRICE = 100 gwei;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    PoolSwapTest internal swapRouter;
    BtcUsdcGasPriceFeeHook internal hook;
    PoolKey internal key;

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
        vm.txGasPrice(INITIAL_GAS_PRICE);
        hook = _deployHook(1, manager, Currency.wrap(WBTC), Currency.wrap(USDC));

        key = PoolKey({
            currency0: Currency.wrap(WBTC),
            currency1: Currency.wrap(USDC),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        manager.initialize(key, SQRT_PRICE_1_1);

        // Dynamic-fee updates must come from the hook address for this hooked pool.
        _setBaseFee(BASE_LP_FEE);

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

    function _setBaseFee(uint24 fee) internal {
        vm.prank(address(hook));
        manager.updateDynamicLPFee(key, fee);
    }

    /// @dev The mainnet pool read is a liveness check on the forked PoolManager, decoupled from the local pool's fee.
    function test_existingMainnetWbtcUsdcPoolIsReadable() public view {
        (uint160 sqrtPriceX96,,, uint24 lpFee) = manager.getSlot0(MAINNET_WBTC_USDC_POOL_ID);

        assertGt(sqrtPriceX96, 0);
        assertLe(lpFee, LPFeeLibrary.MAX_LP_FEE);
    }

    function test_initialMovingAverageState() public view {
        assertEq(hook.movingAverageGasPrice(), INITIAL_GAS_PRICE);
        assertEq(hook.movingAverageGasPriceCount(), 1);
        assertEq(hook.poolBaseFee(key), BASE_LP_FEE);
    }

    /// @dev Exercises every branch and both `>=`/`<=` threshold boundaries against the seeded 100 gwei average.
    function test_currentFeeBranchesAndThresholdBoundaries() public {
        assertEq(hook.poolBaseFee(key), BASE_LP_FEE);

        // High-gas branch: at or above 150% of the 100 gwei average => baseFee / 3.
        vm.txGasPrice(150 gwei); // exactly 150% boundary (inclusive)
        assertEq(hook.currentFee(key), BASE_LP_FEE / 3);
        vm.txGasPrice(151 gwei);
        assertEq(hook.currentFee(key), BASE_LP_FEE / 3);
        vm.txGasPrice(149 gwei); // just below the boundary => normal base fee
        assertEq(hook.currentFee(key), BASE_LP_FEE);

        // Low-gas branch: at or below 50% of the average => baseFee * 2.
        vm.txGasPrice(50 gwei); // exactly 50% boundary (inclusive)
        assertEq(hook.currentFee(key), BASE_LP_FEE * 2);
        vm.txGasPrice(49 gwei);
        assertEq(hook.currentFee(key), BASE_LP_FEE * 2);
        vm.txGasPrice(51 gwei); // just above the boundary => normal base fee
        assertEq(hook.currentFee(key), BASE_LP_FEE);

        // Normal branch.
        vm.txGasPrice(100 gwei);
        assertEq(hook.currentFee(key), BASE_LP_FEE);
    }

    /// @dev The doubled low-gas fee is capped at `MAX_LP_FEE` when twice the base fee would overflow the v4 maximum.
    function test_currentFeeCapsDoubledLowGasFeeAtMaxLpFee() public {
        // 600_000 * 2 = 1_200_000 > MAX_LP_FEE (1_000_000), so the result must be clamped.
        uint24 highBase = 600_000;
        _setBaseFee(highBase);
        assertEq(hook.poolBaseFee(key), highBase);

        vm.txGasPrice(50 gwei); // low-gas branch
        assertEq(hook.currentFee(key), LPFeeLibrary.MAX_LP_FEE);

        vm.txGasPrice(150 gwei); // high-gas branch still divides cleanly
        assertEq(hook.currentFee(key), highBase / 3);
    }

    function test_swapAppliesLowGasFeeAndUpdatesMovingAverage() public {
        uint24 applied = _swapAndGetAppliedFee(50 gwei);
        assertEq(applied, BASE_LP_FEE * 2);

        assertEq(hook.movingAverageGasPrice(), 75 gwei); // (100 + 50) / 2
        assertEq(hook.movingAverageGasPriceCount(), 2);
        assertEq(hook.poolBaseFee(key), BASE_LP_FEE); // override does not persist
    }

    function test_swapAppliesNormalGasFee() public {
        uint24 applied = _swapAndGetAppliedFee(100 gwei);
        assertEq(applied, BASE_LP_FEE);

        assertEq(hook.movingAverageGasPrice(), 100 gwei);
        assertEq(hook.movingAverageGasPriceCount(), 2);
        assertEq(hook.poolBaseFee(key), BASE_LP_FEE);
    }

    function test_swapAppliesHighGasFee() public {
        uint24 applied = _swapAndGetAppliedFee(150 gwei);
        assertEq(applied, BASE_LP_FEE / 3);

        assertEq(hook.movingAverageGasPrice(), 125 gwei); // (100 + 150) / 2
        assertEq(hook.movingAverageGasPriceCount(), 2);
        assertEq(hook.poolBaseFee(key), BASE_LP_FEE);
    }

    /// @dev Each swap prices against the average that existed before it, then folds its own gas price into the average.
    function test_movingAverageAccumulatesAcrossSwaps() public {
        // Seeded: average 100 gwei, count 1.

        // Swap 1 at 400 gwei: priced against 100 gwei average (>=150% => baseFee/3), then average -> (100+400)/2 = 250.
        uint24 applied1 = _swapAndGetAppliedFee(400 gwei);
        assertEq(applied1, BASE_LP_FEE / 3);
        assertEq(hook.movingAverageGasPrice(), 250 gwei);
        assertEq(hook.movingAverageGasPriceCount(), 2);

        // Swap 2 at 100 gwei: priced against 250 gwei average (<=50% => baseFee*2), then average -> (250*2+100)/3 = 200.
        uint24 applied2 = _swapAndGetAppliedFee(100 gwei);
        assertEq(applied2, BASE_LP_FEE * 2);
        assertEq(hook.movingAverageGasPrice(), 200 gwei);
        assertEq(hook.movingAverageGasPriceCount(), 3);

        assertEq(hook.poolBaseFee(key), BASE_LP_FEE);
    }

    /// @dev Executes a swap at `gasPrice` and returns the LP fee the PoolManager actually applied, decoded from the
    /// emitted `Swap` event. Reading the real event (rather than only the hook's quote) verifies the override path
    /// end to end.
    function _swapAndGetAppliedFee(uint256 gasPrice) internal returns (uint24 appliedFee) {
        vm.txGasPrice(gasPrice);

        vm.recordLogs();
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Exact-input zeroForOne swap: spend currency0 (WBTC), receive currency1 (USDC).
        assertLt(delta.amount0(), 0);
        assertGt(delta.amount1(), 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 wantId = PoolId.unwrap(key.toId());
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];
            if (
                log.emitter == address(manager) && log.topics.length == 3 && log.topics[0] == SWAP_EVENT_SIG
                    && log.topics[1] == wantId
            ) {
                (,,,,, appliedFee) = abi.decode(log.data, (int128, int128, uint160, uint128, int24, uint24));
                found = true;
                break;
            }
        }
        assertTrue(found, "Swap event for pool not found");
    }
}
