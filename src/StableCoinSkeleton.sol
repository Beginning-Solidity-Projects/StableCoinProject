// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {ReentrancyGuard} from "lib/forge-std/src/ReentrancyGuard.sol";
import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";
import {AggregatorV3Interface} from "lib/chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {StableCoin} from "./Stablecoin.sol";

contract StableCoinSkeleton is ReentrancyGuard {
    error StablecoinSkeleton_NeedsMoreThanZero();
    error StablecoinSkeleton_TokenAddressAndPriceFeedAddressMustHaveSameLength();
    error StablecoinSkeleton_NotAllowedToken();
    error StablecoinSkeleton_TransferFailed();
    error StablecoinSkeleton_BreaksHealthFactor(uint256 healthFactor);
    error StableCoinSkeleton_MintingFailed();
    error StableCoinSkeleton_HealthFactorIsFine();
    error StableCoinSkeleton_AmountToCoverTooHigh(uint256 amountToCover, uint256 sbtMinted);

    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 50%
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10%
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;

    mapping(address token => address priceFeed) private s_priceFeed;
    mapping(address user => uint256 amountSBTMinted) private s_SBTMinted;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposit;
    address[] private s_collateralTokens;
    Stablecoin private immutable i_stablecoin;

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed user, address indexed token, uint256 indexed amount);

    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert StablecoinSkeleton_NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeed[token] == address(0)) {
            revert StablecoinSkeleton_NotAllowedToken();
        }
        _;
    }


    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address stableCoinAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert StablecoinSkeleton_TokenAddressAndPriceFeedAddressMustHaveSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeed[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_stablecoin = StableCoin(stableCoinAddress);
    }


    function depositCollateralAndMintSBT(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _sbtToMint
    ) external {
        depositCollateral(_tokenCollateralAddress, _amountCollateral);
        mintSBT(_sbtToMint);
    }


    function depositCollateral(address _tokenCollateralAddress, uint256 _amountOfCollateral)
        public
        moreThanZero(_amountOfCollateral)
        isAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposit[msg.sender][_tokenCollateralAddress] += _amountOfCollateral;
        emit CollateralDeposited(msg.sender, _tokenCollateralAddress, _amountOfCollateral);
        bool success = IERC20(_tokenCollateralAddress).transferFrom(msg.sender, address(this), _amountOfCollateral);
        if (!success) {
            revert StablecoinSkeleton_TransferFailed();
        }
    }


    function redeemCollateral(address _tokenCollateralAddress, uint256 _amountOfCollateral)
        public
        moreThanZero(_amountOfCollateral)
        nonReentrant
    {
        s_collateralDeposit[msg.sender][_tokenCollateralAddress] -= _amountOfCollateral;
        emit CollateralRedeemed(msg.sender, _tokenCollateralAddress, _amountOfCollateral);
        bool success = IERC20(_tokenCollateralAddress).transfer(msg.sender, _amountOfCollateral);
        if (!success) {
            revert StablecoinSkeleton_TransferFailed();
        }
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function redeemCollateralForSBT(
        address _tokenCollateralAddress,
        uint256 _amountOfCollateral,
        uint256 _amountOfSBTToBurn
    ) external {
        burnSBT(_amountOfSBTToBurn);
        redeemCollateral(_tokenCollateralAddress, _amountOfCollateral);
        // El factor de salud se comprueba en redeemCollateral
    }


    function mintSBT(uint256 _sbtToMint) public moreThanZero(_sbtToMint) nonReentrant {
        s_SBTMinted[msg.sender] += _sbtToMint;
        revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_stablecoin.mint(msg.sender, _sbtToMint);
        if (!minted) {
            revert StableCoinSkeleton_MintingFailed();
        }
    }


    function burnSBT(uint256 _sbtToBurn) public moreThanZero(_sbtToBurn) nonReentrant {
        s_SBTMinted[msg.sender] -= _sbtToBurn;
        bool success = i_stablecoin.transferFrom(msg.sender, address(this), _sbtToBurn);
        if (!success) {
            revert StablecoinSkeleton_TransferFailed();
        }
        i_stablecoin.burn(_sbtToBurn);
    }


    function liquidate(address _collateral, address _user, uint256 _debtToCover)
        external
        moreThanZero(_debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(_user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert StableCoinSkeleton_HealthFactorIsFine();
        }

        uint256 userSBTMinted = s_SBTMinted[_user];
        if (_debtToCover > userSBTMinted) {
            revert StableCoinSkeleton_AmountToCoverTooHigh(_debtToCover, userSBTMinted);
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(_collateral, _debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(_collateral, totalCollateralToRedeem, _user, msg.sender);
        _burnSbt(_debtToCover, _user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(_user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert();
        }
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function _burnSbt(uint256 _amountSbtToBurn, address _onBehalfOf, address _sbtBurner) private {
        s_SBTMinted[_onBehalfOf] -= _amountSbtToBurn;
        bool success = i_stablecoin.transferFrom(_sbtBurner, address(this), _amountSbtToBurn);
        if (!success) {
            revert StablecoinSkeleton_TransferFailed();
        }
        i_stablecoin.burn(_amountSbtToBurn);
    }

    function _redeemCollateral(
        address _tokenCollateralAddress,
        uint256 _amountOfCollateral,
        address _from,
        address _to
    ) private {
        s_collateralDeposit[_from][_tokenCollateralAddress] -= _amountOfCollateral;
        emit CollateralRedeemed(_from, _tokenCollateralAddress, _amountOfCollateral);
        bool success = IERC20(_tokenCollateralAddress).transfer(_to, _amountOfCollateral);
        if (!success) {
            revert StablecoinSkeleton_TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalSbtMinted, uint256 collateralValueInUsd)
    {
        totalSbtMinted = s_SBTMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }


    function _healthFactor(address _user) private view returns (uint256) {
        (uint256 totalSbtMinted, uint256 collateralValueInUsd) = _getAccountInformation(_user);
        if (totalSbtMinted == 0) return type(uint256).max;

        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalSbtMinted;
    }

    function revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 userHealthFactor = _healthFactor(_user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert StablecoinSkeleton_BreaksHealthFactor(userHealthFactor);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // El precio tiene 8 decimales, lo ajustamos a 18 y luego lo multiplicamos por la cantidad
        return ((uint256(price) * (10**10)) * amount) / PRECISION;
    }


    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // (usdAmountInWei * 1e18) / (precio * 1e10)
        return (usdAmountInWei * PRECISION) / (uint256(price) * (10**10));
    }

    function getAccountCollateralValue(address _user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposit[_user][token];
            if (amount > 0) {
                totalCollateralValueInUsd += getUsdValue(token, amount);
            }
        }
        return totalCollateralValueInUsd;
    }

    function getSbtMinted(address user) external view returns (uint256) {
        return s_SBTMinted[user];
    }

    function getCollateralBalanceOf(address user, address token) external view returns (uint256) {
        return s_collateralDeposit[user][token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
