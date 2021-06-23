//SPDX-License-Identifier: GPL-3.0
pragma solidity 0.7.3;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {DSMath} from "../libraries/DSMath.sol";
import {OracleLibrary} from "../libraries/OracleLibrary.sol";
import {Welford} from "../libraries/Welford.sol";
import {IERC20Detailed} from "../interfaces/IERC20Detailed.sol";
import {Math} from "../libraries/Math.sol";
import {PRBMathSD59x18} from "../libraries/PRBMathSD59x18.sol";

contract VolOracle is DSMath {
    using SafeMath for uint256;

    /**
     * Immutables
     */
    uint32 public immutable period;
    uint256 public immutable annualizationConstant;
    uint8 private immutable baseCurrencyDecimals;
    uint256 internal constant commitPhaseDuration = 1800; // 30 minutes from every period

    /**
     * Storage
     */
    struct Accumulator {
        // Max number of records: 2^16-1 = 65535.
        // If we commit twice a day, we get to have a max of ~89 years.
        uint16 count;
        // Timestamp of the last record
        uint32 lastTimestamp;
        // Smaller size because prices denominated in USDC, max 7.9e27
        uint96 mean;
        // Stores the sum of squared errors
        uint112 m2;
    }

    /// @dev Stores the latest data that helps us compute the standard deviation of the seen dataset.
    mapping(address => Accumulator) public accumulators;

    /// @dev Stores the last oracle TWAP price for a pool
    mapping(address => uint256) public lastPrices;

    /***
     * Events
     */

    event Commit(
        uint16 count,
        uint32 commitTimestamp,
        uint96 mean,
        uint112 m2,
        uint256 newValue,
        address committer
    );

    /**
     * @notice Creates an volatility oracle for a pool
     * @param _pool is the Uniswap v3 pool
     * @param _baseCurrency is the currency to measure the volatility of
     * @param _quoteCurrency is the currency to quote the volatility in
     * @param _period is how often the oracle needs to be updated
     */
    constructor(uint32 _period) {
        IUniswapV3Pool uniPool = IUniswapV3Pool(_pool);
        address token0 = uniPool.token0();
        address token1 = uniPool.token1();

        require(_pool != address(0), "!_pool");
        require(_baseCurrency != address(0), "!_baseCurrency");
        require(_quoteCurrency != address(0), "!_quoteCurrency");
        require(_period > 0, "!_period");

        // Check that the base and quote currencies are part of the pool
        if (_baseCurrency == token0) {
            require(_quoteCurrency == token1, "quote needs to be token1");
        } else if (_baseCurrency == token1) {
            require(_quoteCurrency == token0, "quote needs to be token0");
        } else {
            revert("No matching token");
        }

        pool = _pool;
        baseCurrency = _baseCurrency;
        quoteCurrency = _quoteCurrency;
        baseCurrencyDecimals = IERC20Detailed(_baseCurrency).decimals();
        period = _period;

        // 31536000 seconds in a year
        // divided by the period duration
        // For e.g. if period = 1 day = 86400 seconds
        // It would be 31536000/86400 = 365 days.
        annualizationConstant = Math.sqrt(uint256(31536000).div(_period));
    }

    /**
     * @notice Commits an oracle update
     */
    function commit() external {
        (uint32 commitTimestamp, uint32 gapFromPeriod) = secondsFromPeriod();
        require(gapFromPeriod < commitPhaseDuration, "Not commit phase");

        uint256 price = twap();
        uint256 _lastPrice = lastPrice;
        uint256 periodReturn = _lastPrice > 0 ? wdiv(price, _lastPrice) : 0;

        // logReturn is in 10**18
        // we need to scale it down to 10**8
        int256 logReturn =
            periodReturn > 0
                ? PRBMathSD59x18.ln(int256(periodReturn)) / 10**10
                : 0;

        Accumulator storage accum = accumulator;

        require(
            block.timestamp >=
                accum.lastTimestamp + period - commitPhaseDuration,
            "Committed"
        );

        (uint256 newCount, uint256 newMean, uint256 newM2) =
            Welford.update(accum.count, accum.mean, accum.m2, logReturn);

        require(newCount < type(uint16).max, ">U16");
        require(newMean < type(uint96).max, ">U96");
        require(newM2 < type(uint112).max, ">U112");

        accum.count = uint16(newCount);
        accum.mean = uint96(newMean);
        accum.m2 = uint112(newM2);
        accum.lastTimestamp = commitTimestamp;
        lastPrice = price;

        emit Commit(
            uint16(newCount),
            uint32(commitTimestamp),
            uint96(newMean),
            uint112(newM2),
            price,
            msg.sender
        );
    }

    /**
     * @notice Returns the standard deviation of the base currency in 10**8 i.e. 1*10**8 = 100%
     * @return standardDeviation is the standard deviation of the asset
     */
    function vol() public view returns (uint256 standardDeviation) {
        return Welford.stdev(accumulator.count, accumulator.m2);
    }

    /**
     * @notice Returns the annualized standard deviation of the base currency in 10**8 i.e. 1*10**8 = 100%
     * @return annualStdev is the annualized standard deviation of the asset
     */
    function annualizedVol() public view returns (uint256 annualStdev) {
        return
            Welford.stdev(accumulator.count, accumulator.m2).mul(
                annualizationConstant
            );
    }

    /**
     * @notice Returns the TWAP for the entire Uniswap observation period
     * @return price is the TWAP quoted in quote currency
     */
    function twap(address pool) public view returns (uint256 price) {
        (
            int56 oldestTickCumulative,
            int56 newestTickCumulative,
            uint32 duration
        ) = getTickCumulatives(pool);

        address token0 = uniPool.token0();
        address token1 = uniPool.token1();

        int24 timeWeightedAverageTick =
            getTimeWeightedAverageTick(
                oldestTickCumulative,
                newestTickCumulative,
                duration
            );

        IUniswapV3Pool uniPool = IUniswapV3Pool(pool);

        // Get the price of a unit of asset
        // For ETH, it would be 1 ether (10**18)
        uint128 quoteAmount = uint128(1 * 10**baseCurrencyDecimals);

        return
            OracleLibrary.getQuoteAtTick(
                timeWeightedAverageTick,
                quoteAmount,
                token0,
                token1
            );
    }

    /**
     * @notice Gets the time weighted average tick
     * @return timeWeightedAverageTick is the tick which was resolved to be the time-weighted average
     */
    function getTimeWeightedAverageTick(
        int56 olderTickCumulative,
        int56 newerTickCumulative,
        uint32 duration
    ) private pure returns (int24 timeWeightedAverageTick) {
        int56 tickCumulativesDelta = newerTickCumulative - olderTickCumulative;
        int24 _timeWeightedAverageTick = int24(tickCumulativesDelta / duration);

        // Always round to negative infinity
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % duration != 0))
            _timeWeightedAverageTick--;

        return _timeWeightedAverageTick;
    }

    /**
     * @notice Gets the tick cumulatives which is the tick * seconds
     * @return oldestTickCumulative is the tick cumulative at last index of the observations array
     * @return newestTickCumulative is the tick cumulative at the first index of the observations array
     * @return duration is the TWAP duration determined by the difference between newest-oldest
     */
    function getTickCumulatives(address pool)
        private
        view
        returns (
            int56 oldestTickCumulative,
            int56 newestTickCumulative,
            uint32 duration
        )
    {
        IUniswapV3Pool uniPool = IUniswapV3Pool(pool);

        (, , uint16 newestIndex, uint16 observationCardinality, , , ) =
            uniPool.slot0();

        // Get the latest observation
        (uint32 newestTimestamp, int56 _newestTickCumulative, , ) =
            uniPool.observations(newestIndex);

        // Get the oldest observation
        uint256 oldestIndex = (newestIndex + 1) % observationCardinality;
        (uint32 oldestTimestamp, int56 _oldestTickCumulative, , ) =
            uniPool.observations(oldestIndex);

        uint32 _duration = newestTimestamp - oldestTimestamp;

        return (_oldestTickCumulative, _newestTickCumulative, _duration);
    }

    /**
     * @notice Returns the closest period from the current block.timestamp
     * @return closestPeriod is the closest period timestamp
     * @return gapFromPeriod is the gap between now and the closest period: abs(periodTimestamp - block.timestamp)
     */
    function secondsFromPeriod()
        internal
        view
        returns (uint32 closestPeriod, uint32 gapFromPeriod)
    {
        uint32 timestamp = uint32(block.timestamp);
        uint32 rem = timestamp % period;
        if (rem < period / 2) {
            return (timestamp - rem, rem);
        }
        return (timestamp + period - rem, period - rem);
    }
}
