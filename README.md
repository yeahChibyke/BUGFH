# BTC/USDC Gas Price Fee Hook

A Uniswap v4 hook that adjusts a BTC/USDC pool's LP fee on each swap using the transaction gas price.

The hook is designed for a single configured BTC-side currency and USDC currency. It only works with Uniswap v4 dynamic-fee pools, because the fee returned from `beforeSwap` is a per-swap override rather than a persistent pool fee update.

## How It Works

`BtcUsdcGasPriceFeeHook` reads the pool's stored dynamic LP fee from `PoolManager` and treats that value as the base fee. On every swap, it compares the current transaction gas price to a running average of previously observed gas prices:

| Gas price condition | Fee used for the current swap |
| --- | --- |
| `tx.gasprice >= 150%` of moving average | `baseFee / 3` |
| `tx.gasprice <= 50%` of moving average | `baseFee * 2`, capped at Uniswap v4's max LP fee |
| otherwise | `baseFee` |

The hook returns the selected fee with `LPFeeLibrary.OVERRIDE_FEE_FLAG` from `beforeSwap`. This tells Uniswap v4 to use the adjusted fee for that swap only. The stored pool LP fee is not modified during swaps.

After the swap completes, `afterSwap` records the transaction gas price into a simple arithmetic moving average. That means a swap is priced using the average from before the swap, then its gas price affects future swaps.

## Important Constraints

- The pool must use `LPFeeLibrary.DYNAMIC_FEE_FLAG`.
- The PoolKey currencies must match the BTC and USDC currencies supplied to the hook constructor, in Uniswap v4 sorted order.
- The deployed hook address must contain the before-initialize, before-swap, and after-swap permission bits.
- Existing pools cannot be retrofitted with a hook. The hook must be part of the PoolKey at initialization.
- `tx.gasprice` is an execution-environment signal, not an oracle. The logic is deterministic, but it should not be treated as manipulation-resistant market data.

## Repository Layout

```text
src/BtcUsdcGasPriceFeeHook.sol   Hook implementation
test/TestBUGPFH.t.sol            Mainnet-fork tests
foundry.toml                     Foundry configuration
remappings.txt                   Dependency remappings
```

## Build

```sh
forge build
```

## Test

The test suite is written as a mainnet-fork test. Set `RPC_URL` to an Ethereum mainnet RPC endpoint:

```sh
RPC_URL="https://..." forge test
```

To pin the fork for repeatable results, also set `FORK_BLOCK_NUMBER`:

```sh
RPC_URL="https://..." FORK_BLOCK_NUMBER=12345678 forge test
```

The fork test does two separate things:

1. Reads the existing mainnet WBTC/USDC Uniswap v4 pool to verify the forked `PoolManager` state is accessible.
2. Initializes a new fork-local WBTC/USDC dynamic-fee pool with this hook attached, then verifies the per-swap fee override and moving-average updates.

The second pool is necessary because an already-initialized Uniswap v4 pool cannot have a hook added later.

## Fee Example

If the pool's stored dynamic LP fee is `3_000` pips and the moving average gas price is `100 gwei`:

- `150 gwei` gas price uses `1_000` pips.
- `50 gwei` gas price uses `6_000` pips.
- `100 gwei` gas price uses `3_000` pips.

## Contract Surface

- `poolBaseFee(PoolKey)` returns the pool's stored dynamic LP fee.
- `currentFee(PoolKey)` returns the gas-adjusted fee that would be used in the current call.
- `beforeInitialize` rejects unsupported currency pairs and non-dynamic-fee pools.
- `beforeSwap` returns the per-swap LP fee override.
- `afterSwap` updates the moving average gas price.

