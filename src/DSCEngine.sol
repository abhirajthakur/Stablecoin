// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Abhiraj Thakur
 * @notice This contract is the core of the Decentralized Stable Coin system. It handles all the logic for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is very loosely based on the MakerDAO DSS(DAI) system
 * @dev This contract is meant to be inherited by DecentralizedStableCoin.sol
 *
 * The system is designed to be minimal as possible, and have tokens maintain a "1 token  == 1$ Peg"
 * This stable coin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of any collateral should be less than equal to the value of the all Dollar backed DSC in circulation.
 */
contract DSCEngine is ReentrancyGuard {
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // Collateral value must be 50% more than the loan (DSC) value
    uint256 private constant LIQUIDATION_PRECISON = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidating a user

    mapping(address token => address priceFeed) private _priceFeeds; // token to priceFeeds
    mapping(address user => mapping(address token => uint256 amount)) private _collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private _dscMinted;
    address[] private _collateralTokens;

    DecentralizedStableCoin private immutable _dsc;

    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorBroken(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorNotBroken();
    error DSCEngine__HealthFactorNotImproved();

    /**
     * @param token The address of the token to check
     * @notice This modifier reverts if the token is not allowed
     */
    modifier isAllowedToken(address token) {
        if (_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    /**
     * @param amount The amount to check
     * @notice This modifier reverts if the amount is 0
     */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    /**
     * @param tokenAddresses The array of token addresses
     * @param priceFeedAddresses The array of price feed addresses
     * @param dscAddress The address of the Decentralized Stablecoin
     * @notice This constructor initializes the contract
     * @notice The tokenAddresses and priceFeedAddresses arrays must be the same length
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // Example: ETH / USD, BTC / USD, etc
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            _priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            _collateralTokens.push(tokenAddresses[i]);
        }
        _dsc = DecentralizedStableCoin(dscAddress);
    }

    /**
     * @notice This function allows a user to deposit collateral into the system and mint DSC in one transaction
     * @param collateralTokenAddress The address of token to deposit as collateral
     * @param collateralAmount The amount of collateral to deposit
     * @param dscMintAmount The amount of Decentralized Stablecoin to be minted
     */
    function depositCollateralAndMintDSC(
        address collateralTokenAddress,
        uint256 collateralAmount,
        uint256 dscMintAmount
    ) external {
        depositCollateral(collateralTokenAddress, collateralAmount);
        mintDsc(dscMintAmount);
    }

    /**
     * @param collateralTokenAddress address of the collateral token
     * @param collateralAmount amount of collateral to redeem
     * @param dscBurnAmount amount of DSC to burn
     * @notice This function allows a user to redeem collateral from the system and burn DSC in one transaction
     */
    function redeemCollateralForDSC(address collateralTokenAddress, uint256 collateralAmount, uint256 dscBurnAmount)
        external
    {
        _burnDsc(msg.sender, msg.sender, dscBurnAmount);
        _redeemCollateral(msg.sender, msg.sender, collateralTokenAddress, collateralAmount);
    }

    /**
     * @param collateral The ERC20 collateral address to liquidate
     * @param user the address of user whose health factor is below the threshold
     * @param debtToCover The amount of DSC you want to burn to improve the user's health factor
     * @notice This function allows a user to liquidate another user's position
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation reward for liquidating a user
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorNotBroken();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISON;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDsc(user, msg.sender, debtToCover);

        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= startingHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param amount The amount of DSC to burn
     * @notice This function allows a user to burn DSC
     */
    function burnDsc(uint256 amount) external moreThanZero(amount) {
        _burnDsc(msg.sender, msg.sender, amount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param collateralTokenAddress address of the collateral token
     * @param collateralAmount amount of collateral to redeem
     * @notice This function allows a user to redeem collateral from the system
     */
    function redeemCollateral(address collateralTokenAddress, uint256 collateralAmount)
        external
        moreThanZero(collateralAmount)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, collateralTokenAddress, collateralAmount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @return PRECISION The precision of the price feed
     * @notice This function returns the precision of the price feed
     */
    function getPrecison() external pure returns (uint256) {
        return PRECISION;
    }

    /**
     * @return ADDITIONAL_FEED_PRECISION The additional precision of the price feed
     * @notice This function returns the additional precision of the price feed
     */
    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    /**
     * @return LIQUIDATION_THRESHOLD The liquidation threshold
     * @notice This function returns the liquidation threshold
     */
    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    /**
     * @return LIQUIDATION_BONUS The liquidation bonus
     * @notice This function returns the liquidation bonus
     */
    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    /**
     * @return MIN_HEALTH_FACTOR The minimum health factor allowed
     * @notice This function returns the minimum health factor allowed
     */
    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    /**
     * @return collateralTokens The array of collateral tokens
     * @notice This function returns the array of collateral tokens
     */
    function getCollateralTokens() external view returns (address[] memory) {
        return _collateralTokens;
    }

    /**
     * @param user The address of the user to get the health factor of
     * @return healthFactor The health factor of the user
     * @notice This function returns the health factor of a user
     */
    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /**
     * @param user The address of the user to get the details of
     * @return totalDscMinted The amount of DSC minted by the user
     * @return collateralValueInUsd The collateral value of the user in USD
     * @notice This function returns the details of a user
     */
    function getAccountDetails(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountDetails(user);
    }

    /**
     * @param token The address of the token to get the USD value of
     * @param amount The amount of the token to get the USD value of
     * @return usdValue The USD value of the token
     * @notice This function returns the USD value of a token
     */
    function getUsdValue(
        address token,
        uint256 amount // in WEI
    ) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    /**
     * @param user The address of the user to get the DSC minted of
     * @return dscMinted The amount of DSC minted by the user
     * @notice This function returns the amount of DSC minted by a user
     */
    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return _collateralDeposited[user][token];
    }

    /**
     * @return dsc The address of the Decentralized Stablecoin
     * @notice This function returns the address of the Decentralized Stablecoin
    */
    function getDsc() external view returns (address) {
        return address(_dsc);
    }

    /**
     * @param token The address of the token to get the price feed of
     * @return priceFeed The address of the price feed of the token
     * @notice This function returns the price feed of a token
     */
    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return _priceFeeds[token];
    }

    /**
     * @param collateralTokenAddress The address of token to deposit as collateral
     * @param collateralAmount The amount of collateral to deposit
     * @notice This function allows a user to deposit collateral into the system
     */
    function depositCollateral(address collateralTokenAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        isAllowedToken(collateralTokenAddress)
        nonReentrant
    {
        _collateralDeposited[msg.sender][collateralTokenAddress] += collateralAmount;
        emit CollateralDeposited(msg.sender, collateralTokenAddress, collateralAmount);
        bool success = IERC20(collateralTokenAddress).transferFrom(msg.sender, address(this), collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @param dscAmountToMint The amount of Decentralized Stablecoin to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 dscAmountToMint) public moreThanZero(dscAmountToMint) nonReentrant {
        _dscMinted[msg.sender] += dscAmountToMint;
        // if they minted too much
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = _dsc.mint(msg.sender, dscAmountToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /**
     * @param user The address of the user of which to get the collateral value
     * @return totalCollateralValueInUsd The total collateral value of the user in USD
     * @notice This function returns the collateral value of a user in USC
     */
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // Loops through each collateral token, get the amount they have deposited, and map it to the price to get the USD value
        for (uint256 i = 0; i < _collateralTokens.length; i++) {
            address token = _collateralTokens[i];
            uint256 amount = _collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        // return totalCollateralValueInUsd;
    }

    /**
     * @param token The address of the token to get the amount of
     * @param usdAmountInWei The amount of USD to get the token amount of
     * @notice This function returns the amount of a token given a USD amount
     */
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    /**
     * @param from address of the user from whom to redeem collateral
     * @param to address of the user to whom to send the collateral
     * @param collateralTokenAddress address of the collateral token
     * @param collateralAmount amount of collateral to redeem
     * @notice This function redeems collateral from the system
     */
    function _redeemCollateral(address from, address to, address collateralTokenAddress, uint256 collateralAmount)
        private
    {
        _collateralDeposited[msg.sender][collateralTokenAddress] -= collateralAmount;
        emit CollateralRedeemed(from, to, collateralTokenAddress, collateralAmount);
        bool success = IERC20(collateralTokenAddress).transfer(to, collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @param onBehalfOf address of the user calling this function
     * @param dscFrom address of the user from whom to burn DSC
     * @param dscAmountToBurn amount of DSC to burn
     * @notice This function burns DSC
     * @notice This function also transfers DSC from the user to this contract
     * @dev Low-level internal function. Do not call this function unless the calling function is checking for health factor being broken
     */
    function _burnDsc(address onBehalfOf, address dscFrom, uint256 dscAmountToBurn) private {
        _dscMinted[onBehalfOf] -= dscAmountToBurn;
        bool success = _dsc.transferFrom(dscFrom, address(this), dscAmountToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        _dsc.burn(dscAmountToBurn);
    }

    /**
     * @param totalDscMinted amount of DSC minted by the user
     * @param collateralValueInUsd collateral of the user in USD
     * @notice This function calculates and returns the health factor of a user
     */
    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        private
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISON;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     * @param user address of the user calling this function
     * @notice This function reverts if the health factor of a user is broken
     */
    function _revertIfHealthFactorIsBroken(address user) private view {
        // 1. Check health factor (If they have enough collateral)
        // 2. If not, revert
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorBroken(userHealthFactor);
        }
    }

    /**
     * @param token The address of the token to get the USD value of
     * @param amount The amount of the token to get the USD value of
     * @notice This function returns the USD value of a token
     */
    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // The price value returned will have 8 decimal precison, hence we multiply it by 1^10 so that both price and amount are uint256 and both have 1^18 decimal value
    }

    /**
     * @param user address of the user calling this function
     * @notice This function calculates and returns the health factor of a user
     */
    function _healthFactor(address user) private view returns (uint256) {
        // 1. Get the value of all collateral
        // 2. Get the value of all DSC
        // 3. Return the ratio
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountDetails(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    /**
     * @param user address of the user calling this function
     * @return totalDscMinted amount of DSC minted by the user
     * @return collateralValueInUsd collateral of the user in USD
     * @notice This function returns the details of a user
     */
    function _getAccountDetails(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = _dscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }
}
