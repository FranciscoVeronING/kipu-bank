// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////////////////
//                                  IMPORTS
////////////////////////////////////////////////////////////////////////*/

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV2
 * @author Francisco Veron
 * @notice A multi-asset (ETH & ERC20) digital vault with a USD-based withdrawal limit.
 * @dev This version removes the bank cap for compatibility with volatile assets.
 * @dev It uses AccessControl, Pausable, ReentrancyGuard, and Chainlink Oracles.
 */
contract KipuBankV2 is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
    //                                  CONSTANTS
    ////////////////////////////////////////////////////////////////////////*/

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    address public constant NATIVE_ETH = address(0);
    uint8 public constant USD_DECIMALS = 6;

    /*//////////////////////////////////////////////////////////////////////////
    //                              STATE VARIABLES
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The maximum value (in USD, 6 decimals) allowed per single withdrawal.
     */
    uint256 public immutable i_maxWithdrawUSD;

    uint256 public s_depositCount;
    uint256 public s_withdrawCount;

    /**
     * @notice The maximum age (in seconds) a price feed can be before it's considered "stale".
     */
    uint256 public s_priceFeedMaxAge = 1 hours;

    // --- Token Management Mappings ---
    mapping(address => AggregatorV3Interface) public s_priceFeeds;
    mapping(address => uint8) private s_tokenDecimals;
    mapping(address => uint8) private s_priceFeedDecimals;

    // --- User Balances ---
    mapping(address => mapping(address => uint256)) private s_balances;

    // REMOVED: The s_supportedTokens array. This optimizes admin functions
    // but removes the ability to iterate tokens (e.g., for getUserTotalBalanceUSD).
    // address[] private s_supportedTokens;

    /*//////////////////////////////////////////////////////////////////////////
    //                                  EVENTS
    ////////////////////////////////////////////////////////////////////////*/

    event Deposit(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 valueUSD
    );
    event Withdraw(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 valueUSD
    );
    event TokenSupported(address indexed token, address indexed priceFeed);
    event TokenRemoved(address indexed token);
    event PriceFeedUpdated(address indexed token, address indexed priceFeed);
    event PriceFeedMaxAgeUpdated(uint256 newMaxAge);

    /*//////////////////////////////////////////////////////////////////////////
    //                                  ERRORS
    ////////////////////////////////////////////////////////////////////////*/

    error WithdrawExceedsLimit(uint256 requestedUSD, uint256 maxWithdrawUSD);
    error TransferFailed();
    error TokenNotSupported(address token);
    error TokenAlreadySupported(address token);
    error PriceFeedStale(address token, uint256 lastUpdated);
    error InvalidPriceFeed(address feed);
    error InsufficientBalance(uint256 requested, uint256 available);
    error InvalidAmount();
    error InvalidAddress();
    error CannotRemoveTokenWithFunds();
    error EthDepositsMustUseReceive();

    /*//////////////////////////////////////////////////////////////////////////
    //                                 MODIFIERS
    ////////////////////////////////////////////////////////////////////////*/

    modifier nonZeroAddress(address _addr) {
        if (_addr == address(0)) revert InvalidAddress();
        _;
    }

    modifier isTokenSupported(address _token) {
        if (address(s_priceFeeds[_token]) == address(0)) {
            revert TokenNotSupported(_token);
        }
        _;
    }

    modifier isTokenNotSupported(address _token) {
        if (address(s_priceFeeds[_token]) != address(0)) {
            revert TokenAlreadySupported(_token);
        }
        _;
    }

    modifier isAmountPositive(uint256 _amount) {
        if (_amount == 0) revert InvalidAmount();
        _;
    }

    modifier checkSufficientBalance(address _token, uint256 _amount) {
        uint256 balance = s_balances[msg.sender][_token];
        if (balance < _amount) {
            revert InsufficientBalance(_amount, balance);
        }
        _;
    }

    modifier checkNoFrozenAssets(address _token) {
        if (_getBankTokenBalance(_token) > 0) {
            revert CannotRemoveTokenWithFunds();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
    //                               CONSTRUCTOR
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @param _maxWithdrawUSD Max USD value for a single withdrawal (with 6 decimals).
     * @param _admin The address to be granted ADMIN_ROLE.
     * @param _ethPriceFeed The address of the ETH/USD Chainlink price feed.
     */
    constructor(
        uint256 _maxWithdrawUSD,
        address _admin,
        address _ethPriceFeed
    ) {
        if (_maxWithdrawUSD == 0) revert InvalidAmount();
        if (_admin == address(0)) revert InvalidAddress();
        if (_ethPriceFeed == address(0)) revert InvalidPriceFeed(_ethPriceFeed);

        // Assign core bank limits
        i_maxWithdrawUSD = _maxWithdrawUSD;

        // Assign administrator roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);

        // Natively support ETH (address(0)) from the start
        s_priceFeeds[NATIVE_ETH] = AggregatorV3Interface(_ethPriceFeed);
        s_tokenDecimals[NATIVE_ETH] = 18; // ETH always has 18 decimals
        s_priceFeedDecimals[NATIVE_ETH] = AggregatorV3Interface(_ethPriceFeed)
            .decimals();

        // REMOVED: No event emission in constructor to match user's latest version
        // emit TokenSupported(NATIVE_ETH, _ethPriceFeed);
    }

    /*//////////////////////////////////////////////////////////////////////////
    //                       ETH RECEPTION (receive/fallback)
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Allows the contract to receive native ETH via `send` or `transfer`.
     * @dev Routes to the main deposit logic.
     */
    receive() external payable nonReentrant whenNotPaused {
        _deposit(NATIVE_ETH, msg.value);
    }

    /**
     * @notice Fallback function, also routes to ETH deposit logic.
     */
    fallback() external payable nonReentrant whenNotPaused {
        _deposit(NATIVE_ETH, msg.value);
    }

    /*//////////////////////////////////////////////////////////////////////////
    //                           USER FUNCTIONS (Public)
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits supported ERC20 tokens.
     * @param _token The address of the token to deposit (CANNOT be address(0)).
     * @param _amount The amount of the token to deposit.
     * @dev For ERC20, user must have approved the contract first.
     * @dev To deposit ETH, send it directly to the contract (uses receive()).
     */
    function depositToken(address _token, uint256 _amount)
        external
        nonReentrant
        whenNotPaused
        isTokenSupported(_token)
        nonZeroAddress(_token) // Enforces this is not for ETH
    {
        _deposit(_token, _amount);
    }

    /**
     * @notice Withdraws supported ERC20 tokens or native ETH.
     * @param _token The address of the token to withdraw (use address(0) for ETH).
     * @param _amount The amount of the token to withdraw.
     */
    function withdraw(address _token, uint256 _amount)
        external
        whenNotPaused
        nonReentrant
        isTokenSupported(_token)
        isAmountPositive(_amount)
        checkSufficientBalance(_token, _amount)
    {
        // === CHECKS ===
        uint256 valueUSD = _getUsdValue(_token, _amount);
        if (valueUSD > i_maxWithdrawUSD) {
            revert WithdrawExceedsLimit(valueUSD, i_maxWithdrawUSD);
        }

        // === EFFECTS ===
        s_balances[msg.sender][_token] -= _amount;
        s_withdrawCount += 1;

        // === INTERACTION ===
        _safeTransfer(msg.sender, _token, _amount);

        emit Withdraw(msg.sender, _token, _amount, valueUSD);
    }

    /*//////////////////////////////////////////////////////////////////////////
    //                           VIEW FUNCTIONS (Public)
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the user's balance for a specific token.
     * @param _token The token address (use address(0) for ETH).
     * @return uint256 The amount of the token the user has deposited.
     */
    function getUserTokenBalance(address _token)
        external
        view
        returns (uint256)
    {
        return s_balances[msg.sender][_token];
    }

    // REMOVED: getUserTotalBalanceUSD() because s_supportedTokens array was removed.
    // REMOVED: getSupportedTokens() because s_supportedTokens array was removed.

    /*//////////////////////////////////////////////////////////////////////////
    //                        ADMIN FUNCTIONS (Restricted)
    ////////////////////////////////////////////////////////////////////////*/

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Adds a new ERC20 token to the supported list.
     */
    function addSupportedToken(address _token, address _priceFeed)
        external
        onlyRole(ADMIN_ROLE)
        nonZeroAddress(_token)
        nonZeroAddress(_priceFeed)
        isTokenNotSupported(_token)
    {
        AggregatorV3Interface feed = AggregatorV3Interface(_priceFeed);
        (
            ,
            int256 price,
            ,
            uint256 updatedAt,
            ,
        ) = feed.latestRoundData();
        uint8 feedDecimals = feed.decimals();

        if (price <= 0) revert InvalidPriceFeed(_priceFeed);
        if (block.timestamp - updatedAt > s_priceFeedMaxAge) {
            revert PriceFeedStale(_token, updatedAt);
        }

        s_priceFeeds[_token] = feed;
        s_tokenDecimals[_token] = IERC20Metadata(_token).decimals();
        s_priceFeedDecimals[_token] = feedDecimals;
        // REMOVED: s_supportedTokens.push(_token);

        emit TokenSupported(_token, _priceFeed);
    }

    /**
     * @notice Removes a token from the supported list.
     */
    function removeSupportedToken(address _token)
        external
        onlyRole(ADMIN_ROLE)
        isTokenSupported(_token)
        nonZeroAddress(_token)
        checkNoFrozenAssets(_token)
    {
        delete s_priceFeeds[_token];
        delete s_tokenDecimals[_token];
        delete s_priceFeedDecimals[_token];

        // REMOVED: Array manipulation logic
        // for (uint256 i = 0; i < s_supportedTokens.length; i++) { ... }

        emit TokenRemoved(_token);
    }

    /**
     * @notice Updates the price feed address for an already supported token.
     */
    function updatePriceFeed(address _token, address _priceFeed)
        external
        onlyRole(ADMIN_ROLE)
        isTokenSupported(_token)
        nonZeroAddress(_priceFeed)
    {
        AggregatorV3Interface feed = AggregatorV3Interface(_priceFeed);
        (
            ,
            int256 price,
            ,
            uint256 updatedAt,
            ,
        ) = feed.latestRoundData();
        uint8 feedDecimals = feed.decimals();

        if (price <= 0) revert InvalidPriceFeed(_priceFeed);
        if (block.timestamp - updatedAt > s_priceFeedMaxAge) {
            revert PriceFeedStale(_token, updatedAt);
        }

        s_priceFeeds[_token] = feed;
        s_priceFeedDecimals[_token] = feedDecimals;

        emit PriceFeedUpdated(_token, _priceFeed);
    }

    /**
     * @notice Updates the stale check time for all price feeds.
     */
    function updatePriceFeedMaxAge(uint256 _maxAge)
        external
        onlyRole(ADMIN_ROLE)
        isAmountPositive(_maxAge)
    {
        s_priceFeedMaxAge = _maxAge;
        emit PriceFeedMaxAgeUpdated(_maxAge);
    }

    /*//////////////////////////////////////////////////////////////////////////
    //                       INTERNAL & PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to handle all deposits.
     */
    function _deposit(address _token, uint256 _amount)
        private
        isAmountPositive(_amount)
    {
        // === INTERACTION (Pull) ===
        if (_token != NATIVE_ETH) {
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        }

        // === CHECKS ===
        uint256 valueUSD = _getUsdValue(_token, _amount);

        // === EFFECTS ===
        s_balances[msg.sender][_token] += _amount;
        s_depositCount += 1;

        emit Deposit(msg.sender, _token, _amount, valueUSD);
    }

    /**
     * @notice Internal function to safely transfer ETH or ERC20 tokens *out*.
     */
    function _safeTransfer(address _to, address _token, uint256 _amount)
        private
    {
        if (_token == NATIVE_ETH) {
            (bool success, ) = _to.call{value: _amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }

    /**
     * @notice Internal view function to get the USD value of any token amount.
     */
    function _getUsdValue(address _token, uint256 _amount)
        internal
        view
        returns (uint256)
    {
        AggregatorV3Interface priceFeed = s_priceFeeds[_token];
        (
            ,
            int256 price,
            ,
            uint256 updatedAt,
            ,
        ) = priceFeed.latestRoundData();

        if (price <= 0) revert InvalidPriceFeed(address(priceFeed));
        if (block.timestamp - updatedAt > s_priceFeedMaxAge) {
            revert PriceFeedStale(_token, updatedAt);
        }

        uint8 tokenDecimals = s_tokenDecimals[_token];
        uint8 feedDecimals = s_priceFeedDecimals[_token];

        // This formula is mathematically identical to your (numerator / denom)
        // but performs multiplication first to preserve precision.
        return
            (_amount * uint256(price) * (10**USD_DECIMALS)) /
            (10**tokenDecimals) /
            (10**feedDecimals);
    }

    /**
     * @notice Internal view to get the contract's *actual* balance of a token.
     */
    function _getBankTokenBalance(address _token)
        internal
        view
        returns (uint256)
    {
        if (_token == NATIVE_ETH) {
            return address(this).balance;
        } else {
            return IERC20(_token).balanceOf(address(this));
        }
    }
}