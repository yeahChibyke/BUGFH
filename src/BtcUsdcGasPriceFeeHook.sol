// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-hooks-public/src/base/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

/// @title BTC/USDC Gas Price Fee Hook
/// @notice Uniswap v4 hook that adjusts a BTC/USDC pool's LP fee per swap using the transaction gas price.
/// @dev The hook only supports one configured BTC-side currency and one configured USDC currency. It requires a
/// dynamic-fee PoolKey because the PoolManager only accepts per-swap fee overrides from dynamic-fee pools.
///
/// Fee selection is intentionally stateless with respect to the pool's stored LP fee:
/// - the stored PoolManager LP fee is read as the base fee;
/// - `beforeSwap` returns a fee override for the current swap only;
/// - the stored pool fee is not changed by this hook during swaps.
///
/// The gas threshold is measured against a simple running average of observed `tx.gasprice` values. A transaction at
/// or above 150% of the average receives one third of the base fee. A transaction at or below 50% of the average
/// receives twice the base fee, capped at Uniswap v4's maximum LP fee.
contract BtcUsdcGasPriceFeeHook is BaseHook {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    /// @notice Running arithmetic average of observed `tx.gasprice` values.
    /// @dev Seeded in the constructor with the deployment transaction gas price and updated after every swap routed
    /// through this hook. The value is denominated in wei per gas.
    uint128 public movingAverageGasPrice;

    /// @notice Number of gas-price observations included in `movingAverageGasPrice`.
    /// @dev Starts at one after construction because the constructor records the deployment transaction gas price.
    uint104 public movingAverageGasPriceCount;

    /// @notice BTC-side currency configured for this hook, usually WBTC or another tokenized BTC asset.
    Currency public immutable btcCurrency;

    /// @notice USDC currency configured for this hook.
    Currency public immutable usdcCurrency;

    /// @notice Lower-sorted currency accepted by this hook's PoolKey.
    /// @dev Stored separately so PoolKeys can be validated in Uniswap v4's required currency ordering.
    Currency public immutable poolCurrency0;

    /// @notice Higher-sorted currency accepted by this hook's PoolKey.
    /// @dev Stored separately so PoolKeys can be validated in Uniswap v4's required currency ordering.
    Currency public immutable poolCurrency1;

    /// @notice Thrown when the constructor receives the same currency for BTC and USDC.
    error BUGH__IdenticalCurrencies();

    /// @notice Thrown when a pool tries to initialize with a static LP fee.
    error BUGH__MustUseDynamicFee();

    /// @notice Thrown when a pool other than the configured BTC/USDC pair tries to use this hook.
    error BUGH__UnsupportedPool();

    /// @notice Deploys the hook for a single BTC/USDC currency pair.
    /// @dev The constructor records one gas-price observation. Tests and deployments that care about the initial
    /// average should set the transaction gas price deliberately.
    /// @param _poolManager The Uniswap v4 PoolManager that owns pools and calls hook callbacks.
    /// @param _btcCurrency The BTC-side currency, usually WBTC or another tokenized BTC asset.
    /// @param _usdcCurrency The USDC currency paired with `_btcCurrency`.
    constructor(IPoolManager _poolManager, Currency _btcCurrency, Currency _usdcCurrency) BaseHook(_poolManager) {
        if (_btcCurrency == _usdcCurrency) revert BUGH__IdenticalCurrencies();

        btcCurrency = _btcCurrency;
        usdcCurrency = _usdcCurrency;

        (poolCurrency0, poolCurrency1) =
            _btcCurrency < _usdcCurrency ? (_btcCurrency, _usdcCurrency) : (_usdcCurrency, _btcCurrency);

        _updateMovingAverage();
    }

    /// @notice Declares the hook callbacks implemented by this contract.
    /// @dev The deployed hook address must include the same permission bits: before-initialize, before-swap, and
    /// after-swap. Uniswap v4 validates these bits from the hook address.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Reads the BTC/USDC pool's current stored dynamic LP fee.
    /// @dev This stored value is the base fee used by `_beforeSwap` before gas-price adjustment. It does not include
    /// this hook's per-swap override flag or any temporary gas-price adjustment.
    /// @param _key The BTC/USDC dynamic-fee pool key.
    /// @return The pool-defined base LP fee in pips.
    function poolBaseFee(PoolKey calldata _key) external view returns (uint24) {
        _validateDynamicBtcUsdcPool(_key);

        return _poolLPFee(_key);
    }

    /// @notice Returns the gas-adjusted LP fee that this hook would use for the BTC/USDC pool in the current call.
    /// @dev
    /// This is a read-only quote. It does not set PoolManager state, does not update the moving average, and does not
    /// include `LPFeeLibrary.OVERRIDE_FEE_FLAG`; it returns only the actual LP fee in pips.
    /// @param _key The BTC/USDC dynamic-fee pool key.
    /// @return The current gas-adjusted LP fee in pips.
    function currentFee(PoolKey calldata _key) external view returns (uint24) {
        _validateDynamicBtcUsdcPool(_key);

        return _getFee(_key);
    }

    /// @dev Restricts this hook to the configured BTC/USDC dynamic-fee pool before the pool can be initialized.
    function _beforeInitialize(address, PoolKey calldata _key, uint160) internal view override returns (bytes4) {
        _validateDynamicBtcUsdcPool(_key);

        return this.beforeInitialize.selector;
    }

    /// @dev Computes the current fee and returns it with `OVERRIDE_FEE_FLAG`, which tells PoolManager to use the fee
    /// for this swap only. The hook does not call `updateDynamicLPFee`, so the pool's stored dynamic LP fee remains
    /// available as the base fee for later swaps.
    function _beforeSwap(address, PoolKey calldata _key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 _fee = _getFee(_key);

        // `updateDynamicLPFee` would persist a new pool fee. The override flag scopes the fee to this swap,
        // so every swap is priced from the gas price observed in that same transaction.
        uint24 _feeWithFlag = _fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, _feeWithFlag);
    }

    /// @dev Records the transaction gas price after swap execution. This means the swap itself is priced against the
    /// average that existed before the current swap, then the current gas price is included for future swaps.
    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        _updateMovingAverage();
        return (this.afterSwap.selector, 0);
    }

    /// @dev Adds the current transaction gas price to the running average.
    function _updateMovingAverage() internal {
        uint256 _gasPrice = tx.gasprice;

        // New average = ((old average * observations) + current gas price) / (observations + 1).
        uint256 _newMovingAverage = ((uint256(movingAverageGasPrice) * movingAverageGasPriceCount) + _gasPrice)
            / (movingAverageGasPriceCount + 1);

        // casting to uint128 is safe for practical chain gas prices; tx.gasprice would need to exceed uint128 max
        // to make this average truncate, which is not economically reachable.
        // forge-lint: disable-next-line(unsafe-typecast)
        movingAverageGasPrice = uint128(_newMovingAverage);
        movingAverageGasPriceCount++;
    }

    /// @dev Returns the LP fee for the current transaction gas price.
    /// The base fee is the pool's current stored dynamic LP fee, not a hook-level constant. High gas prices receive a
    /// lower fee to reduce the total cost of execution; low gas prices receive a higher fee, capped by v4's max LP fee.
    function _getFee(PoolKey calldata _key) internal view returns (uint24) {
        uint24 _baseFee = _poolLPFee(_key);
        uint256 _gasPrice = tx.gasprice;
        uint256 _movingAverageGasPrice = movingAverageGasPrice;

        // If gas is at least 150% of the moving average, cut the pool-defined base fee by two thirds.
        if (_gasPrice >= (_movingAverageGasPrice * 150) / 100) {
            return _baseFee / 3;
        }

        // If gas is at most 50% of the moving average, double the pool-defined base fee.
        if (_gasPrice <= (_movingAverageGasPrice * 50) / 100) {
            uint256 _increasedFee = uint256(_baseFee) * 2;
            // casting to uint24 is safe because values above MAX_LP_FEE are returned before the cast
            // forge-lint: disable-next-line(unsafe-typecast)
            return _increasedFee > LPFeeLibrary.MAX_LP_FEE ? LPFeeLibrary.MAX_LP_FEE : uint24(_increasedFee);
        }

        return _baseFee;
    }

    /// @dev Reads the pool's stored LP fee from PoolManager state. For a v4 dynamic-fee pool, this value is used as
    /// the base fee before this hook's per-swap gas adjustment is applied.
    function _poolLPFee(PoolKey calldata _key) internal view returns (uint24 _lpFee) {
        (,,, _lpFee) = poolManager.getSlot0(_key.toId());
    }

    /// @dev Reverts unless the PoolKey is the configured BTC/USDC dynamic-fee pool. The currencies must already be in
    /// Uniswap v4 sorted order.
    function _validateDynamicBtcUsdcPool(PoolKey calldata _key) internal view {
        if (!(_key.currency0 == poolCurrency0) || !(_key.currency1 == poolCurrency1)) {
            revert BUGH__UnsupportedPool();
        }

        if (!_key.fee.isDynamicFee()) revert BUGH__MustUseDynamicFee();
    }
}
