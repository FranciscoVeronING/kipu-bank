# KipuBankV2 - Advanced Multi-Asset Vault

This repository contains the final version of `KipuBankV2`, an advanced smart contract for a multi-asset digital vault. It evolved from a simple ETH-only contract to a production-grade application that manages multiple tokens with USD-based accounting for withdrawals.

This project demonstrates the application of advanced Solidity, security patterns, and robust contract architecture.

## Core Features

* **Multi-Asset Support:** Natively handles both ETH (via `NATIVE_ETH = address(0)`) and any whitelisted ERC-20 token.
* **USD-Based Withdrawal Limit:** Enforces a per-transaction maximum withdrawal limit based on the asset's current value in USD.
* **Chainlink Oracles:** Uses Chainlink Price Feeds to get real-time asset valuations.
* **Role-Based Access Control:** Implements OpenZeppelin's `AccessControl` for a flexible and secure `ADMIN_ROLE`.
* **Emergency Controls:** The contract is `Pausable`, allowing admins to halt deposits and withdrawals in an emergency.
* **Robust Security:**
    * `ReentrancyGuard` on all critical state-changing functions.
    * `SafeERC20` for all token transfers, protecting against non-standard ERC-20s.
    * **Stale Price Feed Protection:** Reverts transactions if the Chainlink price data is too old (default 1 hour).
    * **Asset Freeze Protection:** Prevents admins from removing a token if users still have funds deposited, avoiding locked assets.

## Architectural Decisions & Improvements

This section explains the key design choices that evolved the contract from a simple vault to `KipuBankV2`.

### 1. Key Design Decision: Removal of Bank Capacity Limit

A significant architectural decision was the **explicit removal of a total bank capacity limit** (`i_bankCapUSD`).

* **The Problem:** The initial requirement was to track the total USD value of the bank (`s_totalValueUSD`) and cap it. We identified a fundamental flaw in this model:
    1.  The `s_totalValueUSD` variable would track the value of assets *at the time of deposit* (a historical, "book" value).
    2.  Asset prices are volatile. If a user deposits 1 ETH (worth $2,000) and the price rises to $3,000, their withdrawal would subtract $3,000 from the bank's total, leading to accounting errors or potential underflows.
* **The Solution:** We removed the bank cap entirely. This simplifies the logic and removes the vulnerability. The **per-transaction withdrawal limit** (`i_maxWithdrawUSD`) was kept, as it's calculated using the current price and functions correctly without relying on historical state.

### 2. Security: A Multi-Layered Approach

* **`AccessControl` over `Ownable`:** We use `ADMIN_ROLE`. This is far more flexible than a single `owner`, allowing for multiple admin addresses and future role expansion.
* **`Pausable`:** The `whenNotPaused` modifier is a critical circuit-breaker, allowing admins to call `pause()` to protect all user funds in an emergency.
* **Stale Price Check:** We use `s_priceFeedMaxAge` to ensure we never use an outdated price from a Chainlink feed that might be stuck or deprecated.
* **`checkNoFrozenAssets` Modifier:** This modifier protects users by preventing an admin from removing a token (`removeSupportedToken()`) if the contract's balance of that token is non-zero.

### 3. Gas Optimization: Removal of Token Array

This final version **does not use an iterable array** (`s_supportedTokens`) to track tokens.

* **The Trade-Off:**
    * **Pro (Optimization):** `addSupportedToken` and `removeSupportedToken` are now significantly cheaper in gas, as they only require 1-2 SLOAD/SSTORE operations (mapping) instead of expensive array manipulation.
    * **Con (Functionality):** Without an array to iterate over, we cannot offer a `getUserTotalBalanceUSD()` view function. This was deemed an acceptable trade-off for better admin gas efficiency.

### 4. Function Design: Clarity and Safety

* **Explicit Deposit Functions:** The contract clearly separates deposits:
    * **ETH:** Must be sent directly to the contract via `receive()` or `fallback()`.
    * **ERC-20:** Must use the `depositToken()` function. This function explicitly reverts if `_token == address(0)`.
* **Checks-Effects-Interactions:** The `withdraw()` function strictly follows this pattern:
    1.  **Checks:** `whenNotPaused`, `isTokenSupported`, `isAmountPositive`, `checkSufficientBalance`, and the `i_maxWithdrawUSD` limit.
    2.  **Effects:** The user's `s_balances` and `s_withdrawCount` are updated *before* any transfer.
    3.  **Interaction:** The `_safeTransfer()` (which uses `.call()` for ETH or `safeTransfer` for ERC-20) is the very last step.

## How to Deploy and Interact

### Deployment

1.  **Prerequisites:** You need an `_admin` address and the address for the `_ethPriceFeed` on your target network (e.g., Sepolia).
2.  **Constructor Arguments:** When deploying, you must provide 3 arguments:
    * `_maxWithdrawUSD`: The max USD value for a single withdrawal. (e.g., `1000 * 10**6` for $1,000).
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

#### As a User

1.  **Deposit ERC-20 (e.g., LINK):**
    * **Step 1 (Approve):** Call `approve()` on the LINK token contract, granting `KipuBankV2` an allowance.
        ```solidity
        // On LINK Contract
        approve(KIPUBANK_ADDRESS, 100 * 10**18); // Approve 100 LINK
        ```
    * **Step 2 (Deposit):** Call `depositToken()` on the `KipuBankV2` contract.
        ```solidity
        // On KipuBankV2 Contract
        depositToken(LINK_TOKEN_ADDRESS, 100 * 10**18);
        ```

2.  **Deposit ETH:**
    * Send ETH (e.g., 1 ETH) directly to the `KipuBankV2` contract address from your wallet. The `receive()` function will handle it.

3.  **Check Balance:**
    * Call `getUserTokenBalance(LINK_TOKEN_ADDRESS)` to see your LINK balance.
    * Call `getUserTokenBalance(address(0))` to see your ETH balance.

4.  **Withdraw:**
    * Call `withdraw(LINK_TOKEN_ADDRESS, 50 * 10**18)` to withdraw 50 LINK.
    * Call `withdraw(address(0), 0.5 * 10**18)` to withdraw 0.5 ETH.
