// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4;

import './interfaces/ICapricornFactory.sol';
import './interfaces/ICapricornPair.sol';

import './libraries/CapricornOracleLibrary.sol';
import './libraries/FixedPoint.sol';

import '@openzeppelin/contracts/utils/math/SafeMath.sol';

// sliding window oracle that uses observations collected over a window to provide moving price averages in the past
// `windowSize` with a precision of `windowSize / granularity`
// note this is a singleton oracle and only needs to be deployed once per desired parameters, which
// differs from the simple oracle which must be deployed once per pair.
contract SlidingWindowOracle {
    using FixedPoint for *;
    using SafeMath for uint;

    struct Observation {
        uint timestamp;
        uint price0Cumulative;
        uint price1Cumulative;
    }

    // CapricornSwap Factory
    address public immutable factory;
    // the desired amount of time over which the moving average should be computed, e.g. 24 hours
    uint public immutable windowSize;  // unit: second
    // the number of observations stored for each pair, i.e. how many price observations are stored for the window.
    // as granularity increases from 1, more frequent updates are needed, but moving averages become more precise.
    // averages are computed over intervals with sizes in the range:
    //   [windowSize - (windowSize / granularity) * 2, windowSize]
    // e.g. if the window size is 24 hours, and the granularity is 24, the oracle will return the average price for
    //   the period:
    //   [now - [22 hours, 24 hours], now]
    uint8 public immutable granularity; // unit: count
    // this is redundant with granularity and windowSize, but stored for gas savings & informational purposes.
    uint public immutable periodSize; // unit: second

    // mapping from pair address to a list of price observations of that pair
    mapping(address => Observation[]) public pairObservations;

    // mapping from pair address to last update timestamp of that pair
    mapping(address => uint) public pairLastUpdateTimestamp;

    constructor(address factory_, uint windowSize_, uint8 granularity_) {
        require(granularity_ > 1, 'Granularity less than 1');
        require(
            (periodSize = windowSize_ / granularity_) * granularity_ == windowSize_,
            'WindowSize not evenly divisible'
        );
        factory = factory_;
        windowSize = windowSize_;
        granularity = granularity_;
    }

    // returns the index of the observation corresponding to the given timestamp
    function observationIndexOf(uint timestamp) public view returns (uint8 index) {
        uint epochPeriod = timestamp / periodSize;
        return uint8(epochPeriod % granularity);
    }

    // returns the observation from the oldest epoch (at the beginning of the window) relative to the current time
    function getFirstObservationInWindow(address pair) private view returns (Observation storage firstObservation) {
        uint8 observationIndex = observationIndexOf(block.timestamp);
        uint8 firstObservationIndex = (observationIndex + 1) % granularity;
        firstObservation = pairObservations[pair][firstObservationIndex];
    }

    // update the cumulative price for the observation at the current timestamp. each observation is updated at most
    // once per epoch period.
    function update(address tokenA, address tokenB) public {
        address pair = ICapricornFactory(factory).getPair(tokenA, tokenB);

        // populate the array with empty observations (first call only)
        for (uint i = pairObservations[pair].length; i < granularity; i++) {
            pairObservations[pair].push();
        }

        // get the observation for the current period
        uint8 observationIndex = observationIndexOf(block.timestamp);
        Observation storage observation = pairObservations[pair][observationIndex];

        // only want to commit updates once per period (i.e. windowSize / granularity)
        uint timeElapsed = block.timestamp - observation.timestamp;
        if (timeElapsed > periodSize) {
            (uint price0Cumulative, uint price1Cumulative,) = CapricornOracleLibrary.currentCumulativePrices(pair);
            observation.timestamp = block.timestamp;
            observation.price0Cumulative = price0Cumulative;
            observation.price1Cumulative = price1Cumulative;
            pairLastUpdateTimestamp[pair] = block.timestamp;
        }
    }

    // batch update multi token-pairs
    function batchUpdate(address[] calldata tokenAs, address[] calldata tokenBs) external {
        uint256 tokenAsLength = tokenAs.length;
        uint256 tokenBsLength = tokenBs.length;
        require(tokenAsLength > 0, "tokenAsLength is 0");
        require(tokenAsLength == tokenBsLength, "tokenAsLength should equal tokenBsLength");

        for (uint256 i = 0; i < tokenAsLength; i++) {
            update(tokenAs[i], tokenBs[i]);
        }
    }

    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, 'Identical Addresses');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'Zero Address');
    }

    // given the cumulative prices of the start and end of a period, and the length of the period, compute the average
    // price in terms of how much amount out is received for the amount in
    function computeAmountOut(
        uint priceCumulativeStart, uint priceCumulativeEnd,
        uint timeElapsed, uint amountIn
    ) private pure returns (uint amountOut) {
        FixedPoint.uq112x112 memory priceAverage = FixedPoint.uq112x112(
            uint224((priceCumulativeEnd - priceCumulativeStart) / timeElapsed)
        );
        amountOut = priceAverage.mul(amountIn).decode144();
    }

    // returns the amount out corresponding to the amount in for a given token using the moving average over the time
    // range [now - [windowSize, windowSize - periodSize * 2], now]
    // update must have been called for the bucket corresponding to timestamp `now - windowSize`
    function consult(address tokenIn, uint amountIn, address tokenOut) external view returns (uint amountOut, bool success) {
        address pair = ICapricornFactory(factory).getPair(tokenIn, tokenOut);
        Observation storage firstObservation = getFirstObservationInWindow(pair);

        uint timeElapsed = block.timestamp - firstObservation.timestamp;
        // Missing Historical Observation
        if (timeElapsed > windowSize) {
            return (0, false);
        }

        (uint price0Cumulative, uint price1Cumulative,) = CapricornOracleLibrary.currentCumulativePrices(pair);
        (address token0,) = sortTokens(tokenIn, tokenOut);

        if (token0 == tokenIn) {
            amountOut = computeAmountOut(firstObservation.price0Cumulative, price0Cumulative, timeElapsed, amountIn);
            return (amountOut, true);
        } else {
            amountOut = computeAmountOut(firstObservation.price1Cumulative, price1Cumulative, timeElapsed, amountIn);
            return (amountOut, true);
        }
    }

    // returns pairs last update timestamp
    function getLastUpdateTimestamps(address[] calldata tokenAs, address[] calldata tokenBs) external view returns (uint[] memory, bool) {
        uint256 tokenAsLength = tokenAs.length;
        uint256 tokenBsLength = tokenBs.length;

        if (tokenAsLength <= 0 || tokenAsLength != tokenBsLength) {
             return (new uint[](0), false);
        }

        uint[] memory lastUpdateTimestamps = new uint[](tokenAsLength);
        for (uint256 i = 0; i < tokenAsLength; i++) {
            address pair = ICapricornFactory(factory).getPair(tokenAs[i], tokenBs[i]);
            lastUpdateTimestamps[i] = pairLastUpdateTimestamp[pair];
        }
        return (lastUpdateTimestamps, true);
    }
}
