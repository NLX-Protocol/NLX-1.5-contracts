// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "./interfaces/OracleInterface.sol";
/**
 * @title PythOracle
 * @author Venus
 * @notice PythOracle contract reads prices from actual Pyth oracle contract which accepts, verifies and stores
 * the updated prices from external sources
 */
contract PythOracle is OracleInterface {
    // To calculate 10 ** n(which is a signed type)
    using SignedMath for int256;

    // To cast int64/int8 types from Pyth to unsigned types
    using SafeCast for int256;

    struct TokenConfig {
        bytes32 pythId;
        address asset;
        uint64 maxStalePeriod;
    }
    /// @notice Contract governor address
    address public gov;
    /// @notice Exponent scale (decimal precision) of prices
    uint256 public constant PRICE_PRECISION = 10 ** 30;

    /// @notice The actual pyth oracle address fetch & store the prices
    IPyth public underlyingPythOracle;

    /// @notice Token configs by asset address
    mapping(address => TokenConfig) public tokenConfigs;

    /// @notice Stores the latest Pyth price for each token
    mapping(address => PythStructs.Price) public storedPythPrices;

    /// @notice Emit when setting a new pyth oracle address
    event PythOracleSet(address indexed oldPythOracle, address indexed newPythOracle);

    /// @notice Emit when a token config is added
    event TokenConfigAdded(address indexed asset, bytes32 indexed pythId, uint64 indexed maxStalePeriod);

    /// @notice Emit when a price is updated for a token
    event PriceUpdated(address indexed asset, uint publishTime, int64 price, int32 expo);

    error Unauthorized();

    modifier notNullAddress(address someone) {
        if (someone == address(0)) revert("can't be zero address");
        _;
    }


    constructor(address _underlyingPythOracle) {
        gov = msg.sender;
        underlyingPythOracle = IPyth(_underlyingPythOracle);
        emit PythOracleSet(address(0), _underlyingPythOracle);
    }

    modifier onlyGov() {
        if (msg.sender != gov) revert Unauthorized();
        _;
    }

    function setGov(address newGov) external onlyGov notNullAddress(newGov) {
        gov = newGov;
    }
    /**
     * @notice Batch set token configs
     * @param tokenConfigs_ Token config array
     * @custom:access Only Governance
     * @custom:error Zero length error is thrown if length of the array in parameter is 0
     */
    function setTokenConfigs(TokenConfig[] memory tokenConfigs_) external onlyGov {
        if (tokenConfigs_.length == 0) revert("length can't be 0");
        uint256 numTokenConfigs = tokenConfigs_.length;
        for (uint256 i; i < numTokenConfigs; ) {
            setTokenConfig(tokenConfigs_[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Set the underlying Pyth oracle contract address
     * @param underlyingPythOracle_ Pyth oracle contract address
     * @custom:access Only Governance
     * @custom:error NotNullAddress error thrown if underlyingPythOracle_ address is zero
     * @custom:event Emits PythOracleSet event with address of Pyth oracle.
     */
    function setUnderlyingPythOracle(
        IPyth underlyingPythOracle_
    ) external notNullAddress(address(underlyingPythOracle_)) onlyGov {
        IPyth oldUnderlyingPythOracle = underlyingPythOracle;
        underlyingPythOracle = underlyingPythOracle_;
        emit PythOracleSet(address(oldUnderlyingPythOracle), address(underlyingPythOracle_));
    }

    /**
     * @notice Set single token config. `maxStalePeriod` cannot be 0 and `asset` cannot be a null address
     * @param tokenConfig Token config struct
     * @custom:access Only Governance
     * @custom:error Range error is thrown if max stale period is zero
     * @custom:error NotNullAddress error is thrown if asset address is null
     */
    function setTokenConfig(TokenConfig memory tokenConfig) public notNullAddress(tokenConfig.asset) onlyGov {
        if (tokenConfig.maxStalePeriod == 0) revert("max stale period cannot be 0");
        tokenConfigs[tokenConfig.asset] = tokenConfig;
        emit TokenConfigAdded(tokenConfig.asset, tokenConfig.pythId, tokenConfig.maxStalePeriod);
    }

    /**
     * @notice Gets the price of a asset from the pyth oracle
     * @param asset Address of the asset
     * @return Price in USD
     */
    function getPrice(address asset) public view returns (uint256) {
        return _getPriceInternal(asset);
    }

       /**
     * @notice Updates price feeds in the Pyth oracle and stores the returned price data for each token
     * @param tokens Array of token addresses corresponding to the pythUpdateData
     * @param pythUpdateData Data to update Pyth prices
     */
    function updatePythPrices(address[] memory tokens, bytes[] memory pythUpdateData) external payable {

        require(pythUpdateData.length > 0, "Price update data cannot be empty"); 
        uint256 updateFee = underlyingPythOracle.getUpdateFee(pythUpdateData);
        require(updateFee <= msg.value, "Not enough funds to update price feeds");

        underlyingPythOracle.updatePriceFeeds{value: updateFee}(pythUpdateData);

        // Iterate through each token and store the updated price
        uint256 tokensLength = tokens.length;
        for (uint256 i; i < tokensLength;) {
            PythStructs.Price memory updatedPrice = underlyingPythOracle.getPriceNoOlderThan(tokenConfigs[tokens[i]].pythId, tokenConfigs[tokens[i]].maxStalePeriod);
            address asset = tokens[i];
            storedPythPrices[asset] = updatedPrice;
            emit PriceUpdated(asset, updatedPrice.publishTime, updatedPrice.price, updatedPrice.expo);

            unchecked { ++i; }
        }

        uint256 excess = msg.value - updateFee;
        if (excess > 0) {
            (bool success, ) = msg.sender.call{value: excess}("");
            require(success, "Refund failed");
        }
    }

    /**
     * @notice Gets the price feed ID for an array of tokens
     * @param tokens Array of token addresses
     * @return pythIds Array of price feed IDs corresponding to the tokens
     */
    function getPriceFeedIds(address[] memory tokens) external view returns (bytes32[] memory pythIds) {

        uint256 tokensLength = tokens.length;
        pythIds = new bytes32[](tokensLength);
        for (uint256 i = 0; i < tokensLength;) {
            pythIds[i] = tokenConfigs[tokens[i]].pythId;

            unchecked { ++i; }

        }
    }

    function _getPriceInternal(address asset) internal view returns (uint256 price) {
        TokenConfig storage tokenConfig = tokenConfigs[asset];
        if (tokenConfig.asset == address(0)) revert("asset doesn't exist");

        // if the price is expired after it's compared against `maxStalePeriod`, the following call will revert
        PythStructs.Price memory priceInfo = underlyingPythOracle.getPriceNoOlderThan(
            tokenConfig.pythId,
            tokenConfig.maxStalePeriod
        );

        if (priceInfo.price == 0) {
            // Use stored Pyth price if current price is zero
            priceInfo = storedPythPrices[asset];
            if (priceInfo.price == 0) revert("invalid pyth oracle price");
        }

        uint256 pricePrecision = PRICE_PRECISION; // 1e30
        uint256 basePrice = int256(priceInfo.price).toUint256();

        if (priceInfo.expo > 0) {
            price = basePrice * (10 ** uint256(int256(priceInfo.expo))) * pricePrecision;
        } else {
            price = (basePrice * pricePrecision) / (10 ** uint256(-int256(priceInfo.expo)));
        }
    }
}
