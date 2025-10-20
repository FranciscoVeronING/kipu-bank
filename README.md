# KipuBankV2 - Advanced Multi-Asset Vault

This repository contains the final version of `KipuBankV2`, an advanced smart contract for a multi-asset digital vault. It evolved from a simple ETH-only contract to a production-grade application that manages multiple tokens with USD-based accounting.

## Core Features

* **Multi-Asset Support:** Natively handles both ETH (via `NATIVE_ETH = address(0)`) and any whitelisted ERC-20 token.
* **USD-Based Limits:** All accounting (total capacity and withdrawal limits) is based on the assets' value in USD, not their token quantity.
* **Chainlink Oracles:** Uses Chainlink Price Feeds to get real-time asset valuations.
* **Role-Based Access Control:** Implements OpenZeppelin's `AccessControl` for a flexible and secure `ADMIN_ROLE`, superior to a single `owner`.
* **Emergency Controls:** The contract is `Pausable`, allowing admins to halt deposits and withdrawals in an emergency.
* **Robust Security:**
    * `ReentrancyGuard` on all critical state-changing functions.
    * `SafeERC20` for all token transfers, protecting against non-standard ERC-20s.
    * **Stale Price Feed Protection:** Reverts transactions if the Chainlink price data is too old (default 1 hour).
    * **Asset Freeze Protection:** Prevents admins from removing a token if users still have funds deposited, avoiding locked assets.

## Architectural Decisions & Improvements

This section explains the key design choices that evolved the contract from a simple vault to `KipuBankV2`.

### 1. Security: A Multi-Layered Approach

Security was the highest priority. We moved beyond basic checks to a more comprehensive model:

* **`AccessControl` over `Ownable`:** Instead of a single "owner", we use `ADMIN_ROLE`. This is far more flexible, allowing for multiple admin addresses and the future addition of granular roles (e.g., a `PRICE_UPDATER_ROLE`) without changing the core logic.
* **`Pausable`:** The `whenNotPaused` modifier is a critical circuit-breaker. If a vulnerability is found or an oracle behaves unexpectedly, admins can call `pause()` to protect all user funds.
* **Stale Price Check:** This is a vital security feature. We use `s_priceFeedMaxAge` to ensure we never use an outdated price from a Chainlink feed that might be stuck or deprecated. The `_getUsdValue` function checks this on *every* valuation.
* **`checkNoFrozenAssets` Modifier:** This modifier protects users from a rogue or careless admin. It prevents `removeSupportedToken()` from being called if the contract's balance of that token is non-zero, ensuring users can always withdraw their funds.

### 2. Accounting: USD Normalization & Data Management

The core requirement was to account for value in USD, not in token amounts.

* **USD Normalization:** We defined `USD_DECIMALS = 6`. All internal value tracking (`i_bankCapUSD`, `i_maxWithdrawUSD`, `s_totalValueUSD`) is normalized to 6 decimals, similar to USDC, providing a consistent standard for calculation.
* **Token Data Storage:** Instead of a `struct`, we use separate mappings (`s_priceFeeds`, `s_tokenDecimals`, `s_priceFeedDecimals`). This is complemented by the `s_supportedTokens` array.
* **Why the Array?** The `s_supportedTokens` array is crucial. It allows us to *iterate* over all supported tokens, which is necessary for the `getUserTotalBalanceUSD()` function to calculate a user's total portfolio value.

### 3. Function Design: Clarity and Safety

* **Unified Deposit Logic:** The `deposit()` function is the single entry point for users. It intelligently handles both ERC-20s (pulling funds with `safeTransferFrom`) and Native ETH (checking `msg.value`). The `receive()` and `fallback()` functions simply route ETH deposits to the internal `_deposit()` logic.
* **Checks-Effects-Interactions:** The `withdraw()` function strictly follows this pattern:
    1.  **Checks:** `whenNotPaused`, `isTokenSupported`, `isAmountPositive`, `checkSufficientBalance`, and the `i_maxWithdrawUSD` limit.
    2.  **Effects:** The user's `s_balances` and the contract's `s_totalValueUSD` are updated *before* any transfer.
    3.  **Interaction:** The `_safeTransfer()` (which uses `.call()` for ETH or `safeTransfer` for ERC-20) is the very last step.

## How to Deploy and Interact

### Deployment

1.  **Prerequisites:** You need an `_admin` address and the address for the `_ethPriceFeed` on your target network (e.g., Sepolia).
2.  **Constructor Arguments:** When deploying, you must provide 4 arguments:
    * `_maxWithdrawUSD`: The max USD value for a single withdrawal. (e.g., `1000 * 10**6` for $1,000).
    * `_bankCapUSD`: The total USD capacity of the bank. (e.g., `1000000 * 10**6` for $1,000,000).
    * `_admin`: The wallet address that will receive the `ADMIN_ROLE`.
    * `_ethPriceFeed`: The address of the ETH/USD price feed.

### Interaction Flow

#### As an Admin (ADMIN\_ROLE required)

1.  **Add a Token (e.g., LINK):**
    * Find the LINK token address and the LINK/USD Price Feed address for your network.
    * Call `addSupportedToken(LINK_TOKEN_ADDRESS, LINK_PRICE_FEED_ADDRESS)`.

2.  **Handle an Emergency:**
    * Call `pause()` to stop deposits and withdrawals.
    * Once the issue is resolved, call `unpause()`.

3.  **Update a Price Feed:**
    * If a feed is deprecated, call `updatePriceFeed(TOKEN_ADDRESS, NEW_PRICE_FEED_ADDRESS)`.

#### As a User

1.  **Deposit ERC-20 (e.g., LINK):**
    * **Step 1 (Approve):** Call `approve()` on the LINK token contract, granting `KipuBankV2` an allowance.
        ```solidity
        // On LINK Contract
        approve(KIPUBANK_ADDRESS, 100 * 10**18); // Approve 100 LINK
        ```
    * **Step 2 (Deposit):** Call `deposit()` on the `KipuBankV2` contract.
        ```solidity
        // On KipuBankV2 Contract
        deposit(LINK_TOKEN_ADDRESS, 100 * 10**18);
        ```

2.  **Deposit ETH:**
    * Call `deposit()` specifying the `NATIVE_ETH` address (`address(0)`) and sending the ETH in the `value` field.
        ```solidity
        // On KipuBankV2 Contract
        // Send 1 ETH
        deposit(address(0), 1 * 10**18, {value: 1 * 10**18});
        ```
    * *Alternatively*, you can just send ETH directly to the contract address (via `receive()`).

3.  **Check Balance:**
    * Call `getUserTokenBalance(LINK_TOKEN_ADDRESS)` to see your LINK balance.
    * Call `getUserTotalBalanceUSD()` to see the total USD value of all your assets in the vault.

4.  **Withdraw:**
    * Call `withdraw(LINK_TOKEN_ADDRESS, 50 * 10**18)` to withdraw 50 LINK.
    * Call `withdraw(address(0), 0.5 * 10**18)` to withdraw 0.5 ETH.
