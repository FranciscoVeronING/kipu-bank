// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////////////////
//                              IMPORTS
////////////////////////////////////////////////////////////////////////*/

// For role-based access control (e.g., ADMIN_ROLE)
import "@openzeppelin/contracts/access/AccessControl.sol";
// For pausing the contract in case of emergency
import "@openzeppelin/contracts/utils/Pausable.sol";
// For preventing re-entrancy attacks on critical functions
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
// For safe ERC20 transfers (handles tokens that don't return bool)
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// For reading token metadata like `decimals()`
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
// For interacting with Chainlink Price Feeds
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV2
 * @author Francisco Veron
 * @notice A multi-asset (ETH & ERC20) digital vault with USD-based limits.
 * @dev This contract uses:
 *       - AccessControl: For a flexible ADMIN_ROLE.
 *       - Pausable: To halt deposits/withdrawals in an emergency.
 *       - ReentrancyGuard: To protect state-changing functions.
 *       - Chainlink Oracles: To value assets in USD.
 *       - SafeERC20: For robust token transfers.
 */
contract KipuBankV2 is AccessControl, Pausable, ReentrancyGuard {
    // Apply SafeERC20 library to all IERC20 instances
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
    //                             CONSTANTS
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Defines the administrator role.
     * @dev Only addresses with this role can manage tokens and pause the contract.
     */
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /**
     * @notice We use address(0) to represent native ETH in our internal accounting.
     */
    address public constant NATIVE_ETH = address(0);

    /**
     * @notice All internal USD accounting is normalized to 6 decimals, like USDC.
     */
    uint8 public constant USD_DECIMALS = 6;

    /*//////////////////////////////////////////////////////////////////////////
    //                         STATE VARIABLES
    ////////////////////////////////////////////////////////////////////////*/

    // --- Immutable Limits ---
    // These are set in the constructor and can never be changed.

    /**
     * @notice The maximum total value (in USD, 6 decimals) the bank can hold.
     */
    uint256 public immutable i_bankCapUSD;

    /**
     * @notice The maximum value (in USD, 6 decimals) allowed per single withdrawal.
     */
    uint256 public immutable i_maxWithdrawUSD;

    // --- Storage Variables ---

    /**
     * @notice The current total value of all assets held by the bank (in USD, 6 decimals).
     */
    uint256 public s_totalValueUSD;

    /**
     * @notice A global counter for total successful deposits.
     */
    uint256 public s_depositCount;

    /**
     * @notice A global counter for total successful withdrawals.
     */
    uint256 public s_withdrawCount;

    /**
     * @notice The maximum age (in seconds) a price feed can be before it's considered "stale".
     * @dev Default is 1 hour. This prevents operating with outdated prices.
     */
    uint256 public s_priceFeedMaxAge = 1 hours;

    // --- Token Management Mappings ---

    /**
     * @notice Maps a token address to its Chainlink price feed contract.
     * @dev Example: WETH_ADDRESS => ETH/USD Price Feed Address
     */
    mapping(address => AggregatorV3Interface) public s_priceFeeds;

    /**
     * @notice Caches the `decimals` of each supported token (e.g., 18 for WETH, 6 for USDC).
     */
    mapping(address => uint8) private s_tokenDecimals;

    /**
     * @notice Caches the `decimals` of each token's price feed (e.g., 8 for ETH/USD).
     */
    mapping(address => uint8) private s_priceFeedDecimals;

    // --- User Balances ---

    /**
     * @notice Nested mapping to track each user's balance for each token.
     * @dev s_balances[user_address][token_address] = token_amount
     */
    mapping(address => mapping(address => uint256)) private s_balances;

    /**
     * @notice An array of all supported token addresses.
     * @dev This allows us to iterate over all tokens (e.g., to calculate total balance).
     */
    address[] private s_supportedTokens;

    /*//////////////////////////////////////////////////////////////////////////
    //                               EVENTS
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
    //                               ERRORS
    ////////////////////////////////////////////////////////////////////////*/

    error BankIsFull(uint256 spaceAvailableUSD);
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

    /*//////////////////////////////////////////////////////////////////////////
    //                            MODIFIERS
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @dev Reverts if the `_addr` is the zero address.
     */
    modifier nonZeroAddress(address _addr) {
        if (_addr == address(0)) revert InvalidAddress();
        _;
    }

    /**
     * @dev Reverts if the `_token` is not in our list of supported tokens.
     */
    modifier isTokenSupported(address _token) {
        if (address(s_priceFeeds[_token]) == address(0)) {
            revert TokenNotSupported(_token);
        }
        _;
    }

    /**
     * @dev Reverts if the `_token` is already in our list.
     */
    modifier isTokenNotSupported(address _token) {
        if (address(s_priceFeeds[_token]) != address(0)) {
            revert TokenAlreadySupported(_token);
        }
        _;
    }

    /**
     * @dev Reverts if the `_amount` is zero.
     */
    modifier isAmountPositive(uint256 _amount) {
        if (_amount == 0) revert InvalidAmount();
        _;
    }

    /**
     * @dev Reverts if the `msg.sender` does not have enough balance of `_token`.
     */
    modifier checkSufficientBalance(address _token, uint256 _amount) {
        uint256 balance = s_balances[msg.sender][_token];
        if (balance < _amount) {
            revert InsufficientBalance(_amount, balance);
        }
        _;
    }

    /**
     * @dev Reverts if an admin tries to remove a token that still has funds
     *       in the contract. This prevents freezing user assets.
     */
    modifier checkNoFrozenAssets(address _token) {
        if (_getBankTokenBalance(_token) > 0) {
            revert CannotRemoveTokenWithFunds();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
    //                            CONSTRUCTOR
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @param _maxWithdrawUSD Max USD value for a single withdrawal (with 6 decimals).
     * @param _bankCapUSD Total USD value the bank can hold (with 6 decimals).
     * @param _admin The address to be granted ADMIN_ROLE.
     * @param _ethPriceFeed The address of the ETH/USD Chainlink price feed.
     */
    constructor(
        uint256 _maxWithdrawUSD,
        uint256 _bankCapUSD,
        address _admin,
        address _ethPriceFeed
    ) {
        if (_maxWithdrawUSD == 0 || _bankCapUSD == 0) revert InvalidAmount();
        if (_admin == address(0)) revert InvalidAddress();
        if (_ethPriceFeed == address(0)) revert InvalidPriceFeed(_ethPriceFeed);

        // Assign core bank limits
        i_maxWithdrawUSD = _maxWithdrawUSD;
        i_bankCapUSD = _bankCapUSD;

        // Assign administrator roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);

        // Natively support ETH (address(0)) from the start
        s_priceFeeds[NATIVE_ETH] = AggregatorV3Interface(_ethPriceFeed);
        s_supportedTokens.push(NATIVE_ETH);
        s_tokenDecimals[NATIVE_ETH] = 18; // ETH always has 18 decimals
        s_priceFeedDecimals[NATIVE_ETH] = AggregatorV3Interface(_ethPriceFeed)
            .decimals();

        emit TokenSupported(NATIVE_ETH, _ethPriceFeed);
    }

    /*//////////////////////////////////////////////////////////////////////////
    //                       ETH RECEPTION (receive/fallback)
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Allows the contract to receive native ETH via `send` or `transfer`.
     * @dev This is a convenience for users. It routes to the main deposit logic.
     */
    receive() external payable nonReentrant {
        // `msg.value` contains the amount of ETH sent.
        _deposit(NATIVE_ETH, msg.value);
    }

    /**
     * @notice Fallback function, also routes to ETH deposit logic.
     */
    fallback() external payable nonReentrant {
        _deposit(NATIVE_ETH, msg.value);
    }

    /*//////////////////////////////////////////////////////////////////////////
    //                        USER FUNCTIONS (Public)
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits supported ERC20 tokens or native ETH.
     * @param _token The address of the token to deposit (use address(0) for ETH).
     * @param _amount The amount of the token to deposit.
     * @dev For ETH, `msg.value` must equal `_amount`.
     * @dev For ERC20, user must have approved the contract first.
     */
    function deposit(address _token, uint256 _amount)
        external
        payable
        isTokenSupported(_token)
        nonReentrant
    {
        if (_token == NATIVE_ETH) {
            // If depositing ETH, msg.value must match the specified amount
            if (msg.value != _amount) revert InvalidAmount();
        }
        _deposit(_token, _amount);
    }

    /**
     * @notice Withdraws supported ERC20 tokens or native ETH.
     * @param _token The address of the token to withdraw (use address(0) for ETH).
     * @param _amount The amount of the token to withdraw.
     */
    function withdraw(address _token, uint256 _amount)
        external
        // Modifiers apply from top to bottom
        whenNotPaused // Reverts if contract is paused
        nonReentrant // Prevents re-entrancy attacks
        isTokenSupported(_token) // Checks if token is valid
        isAmountPositive(_amount) // Checks if amount > 0
        checkSufficientBalance(_token, _amount) // Checks if user has enough funds
    {
        // === CHECKS ===
        // 1. Check if the withdrawal value exceeds the per-transaction limit
        uint256 valueUSD = _getUsdValue(_token, _amount);
        if (valueUSD > i_maxWithdrawUSD) {
            revert WithdrawExceedsLimit(valueUSD, i_maxWithdrawUSD);
        }

        // === EFFECTS ===
        // 2. Update user and contract state *before* the transfer
        s_balances[msg.sender][_token] -= _amount;
        s_totalValueUSD -= valueUSD; // Safe from underflow due to balance check
        s_withdrawCount += 1;

        // === INTERACTION ===
        // 3. Transfer the funds to the user
        _safeTransfer(msg.sender, _token, _amount);

        // 4. Emit event
        emit Withdraw(msg.sender, _token, _amount, valueUSD);
    }

    /*//////////////////////////////////////////////////////////////////////////
    //                       VIEW FUNCTIONS (Public)
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

    /**
     * @notice Calculates the total USD value of all tokens held by the user.
     * @return totalUSD The user's total balance, in USD (6 decimals).
     */
    function getUserTotalBalanceUSD() external view returns (uint256 totalUSD) {
        totalUSD = 0;
        // Iterate over the array of supported tokens
        for (uint256 i = 0; i < s_supportedTokens.length; i++) {
            address token = s_supportedTokens[i];
            uint256 balance = s_balances[msg.sender][token];
            if (balance > 0) {
                // Add this token's USD value to the total
                totalUSD += _getUsdValue(token, balance);
            }
        }
    }

    /**
     * @notice Returns the remaining USD capacity of the bank.
     * @return uint256 The available space, in USD (6 decimals).
     */
    function getAvailableBankSpaceUSD() external view returns (uint256) {
        if (i_bankCapUSD > s_totalValueUSD) {
            return i_bankCapUSD - s_totalValueUSD;
        }
        return 0; // Bank is full
    }

    /**
     * @notice Returns the list of all supported token addresses.
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return s_supportedTokens;
    }

    /*//////////////////////////////////////////////////////////////////////////
    //                    ADMIN FUNCTIONS (Restricted)
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Pauses deposits and withdrawals.
     * @dev Only callable by ADMIN_ROLE.
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Resumes deposits and withdrawals.
     * @dev Only callable by ADMIN_ROLE.
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Adds a new ERC20 token to the supported list.
     * @param _token The token's contract address.
     * @param _priceFeed The token's Chainlink Price Feed address (e.g., LINK/USD).
     */
    function addSupportedToken(address _token, address _priceFeed)
        external
        onlyRole(ADMIN_ROLE)
        nonZeroAddress(_token)
        nonZeroAddress(_priceFeed)
        isTokenNotSupported(_token)
    {
        AggregatorV3Interface feed = AggregatorV3Interface(_priceFeed);

        // Check the feed for validity before adding it
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

        // Add the token to storage
        s_priceFeeds[_token] = feed;
        s_supportedTokens.push(_token);
        s_tokenDecimals[_token] = IERC20Metadata(_token).decimals();
        s_priceFeedDecimals[_token] = feedDecimals;

        emit TokenSupported(_token, _priceFeed);
    }

    /**
     * @notice Removes a token from the supported list.
     * @param _token The token's contract address.
     * @dev Will fail if the contract still holds any of this token,
     *       to prevent freezing user assets.
     */
    function removeSupportedToken(address _token)
        external
        onlyRole(ADMIN_ROLE)
        isTokenSupported(_token)
        nonZeroAddress(_token) // Cannot remove NATIVE_ETH (address(0))
        checkNoFrozenAssets(_token)
    {
        // Delete from mappings
        delete s_priceFeeds[_token];
        delete s_tokenDecimals[_token];
        delete s_priceFeedDecimals[_token];

        // Remove from the array (efficiently)
        uint256 length = s_supportedTokens.length;
        for (uint256 i = 0; i < length; i++) {
            if (s_supportedTokens[i] == _token) {
                // Swap with the last element and pop
                s_supportedTokens[i] = s_supportedTokens[length - 1];
                s_supportedTokens.pop();
                break;
            }
        }

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

        // Check the new feed for validity
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

        // Update the feed and its decimals
        s_priceFeeds[_token] = feed;
        s_priceFeedDecimals[_token] = feedDecimals;

        emit PriceFeedUpdated(_token, _priceFeed);
    }

    /**
     * @notice Updates the stale check time for all price feeds.
     * @param _maxAge The new max age in seconds.
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
    //                   INTERNAL & PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to handle all deposits.
     * @dev This is the core logic called by `deposit()`, `receive()`, and `fallback()`.
     */
    function _deposit(address _token, uint256 _amount)
        private
        whenNotPaused // Reverts if contract is paused
        isAmountPositive(_amount) // Reverts if _amount is 0
    {
        // === INTERACTION (Pull) ===
        // 1. If it's an ERC20, pull the tokens from the user.
        // This is safe to do before Checks/Effects because it's a `transferFrom`
        // from msg.sender and is protected by the `nonReentrant` guard.
        if (_token != NATIVE_ETH) {
            // `SafeERC20` handles tokens that don't return bool
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        }

        // === CHECKS ===
        // 2. Get the USD value and check if it exceeds the bank's total capacity
        uint256 valueUSD = _getUsdValue(_token, _amount);
        uint256 newTotalValueUSD = s_totalValueUSD + valueUSD;

        if (newTotalValueUSD > i_bankCapUSD) {
            revert BankIsFull(i_bankCapUSD - s_totalValueUSD);
        }

        // === EFFECTS ===
        // 3. Update the user's balance and the bank's total value
        s_balances[msg.sender][_token] += _amount;
        s_totalValueUSD = newTotalValueUSD;
        s_depositCount += 1;

        // 4. Emit event
        emit Deposit(msg.sender, _token, _amount, valueUSD);
    }

    /**
     * @notice Internal function to safely transfer ETH or ERC20 tokens *out*.
     */
    function _safeTransfer(address _to, address _token, uint256 _amount)
        private
    {
        if (_token == NATIVE_ETH) {
            // Send native ETH
            (bool success, ) = _to.call{value: _amount}("");
            if (!success) revert TransferFailed();
        } else {
            // Send ERC20 token
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }

    /**
     * @notice Internal view function to get the USD value of any token amount.
     * @dev This is the core conversion logic.
     */
    function _getUsdValue(address _token, uint256 _amount)
        internal
        view
        returns (uint256)
    {
        // 1. Get price feed data
        AggregatorV3Interface priceFeed = s_priceFeeds[_token];
        (
            ,
            int256 price, // e.g., 300000000000 (for ETH/USD with 8 decimals)
            ,
            uint256 updatedAt, // Timestamp of last update
            ,
        ) = priceFeed.latestRoundData();

        // 2. Security checks on the price data
        if (price <= 0) revert InvalidPriceFeed(address(priceFeed));
        if (block.timestamp - updatedAt > s_priceFeedMaxAge) {
            revert PriceFeedStale(_token, updatedAt);
        }

        // 3. Get token and feed decimals
        uint8 tokenDecimals = s_tokenDecimals[_token]; // e.g., 18 for ETH
        uint8 feedDecimals = s_priceFeedDecimals[_token]; // e.g., 8 for ETH/USD

        // 4. Calculate the value
        // Example (1 ETH):
        // (1 * 10^18) * (3000 * 10^8) * (10^6) = 3000 * 10^32
        // (10^18) * (10^8) = 10^26
        // (3000 * 10^32) / (10^26) = 3000 * 10^6
        // Result: 3,000 USD with 6 decimals.
        return
            (_amount * uint256(price) * (10**USD_DECIMALS)) /
            (10**tokenDecimals) /
            (10**feedDecimals);
    }

    /**
     * @notice Internal view to get the contract's *actual* balance of a token.
     * @dev Used by `checkNoFrozenAssets` to see if funds are still in the bank.
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