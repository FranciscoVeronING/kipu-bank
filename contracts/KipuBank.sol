// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title KipuBank - Personal Vault with Per-Transaction and Global Limit
/// @author FranciscoVeron
/// @notice Example contract for a vault that allows ETH deposits and withdrawals
///         subject to a per-transaction limit and a global bank capacity.
/// @dev Implements essential security practices: custom errors, Checks-Effects-Interactions,
///      simple reentrancy guard, NatSpec, and constructor validation.
contract KipuBank {
    /*//////////////////////////////////////////////////////////////////////////
                                      ERRORS
    /////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when a deposit would exceed the bank's global capacity
    error ExceedsBankCap(uint256 attempted, uint256 bankCap);

    /// @notice Thrown when the requested withdrawal amount exceeds the user's balance
    error InsufficientBalance(address account, uint256 balance, uint256 requested);

    /// @notice Thrown when the requested withdrawal amount exceeds the per-transaction limit
    error ExceedsWithdrawLimit(uint256 requested, uint256 withdrawLimit);

    /// @notice Thrown when attempting to deposit or withdraw a non-positive amount (zero)
    error NotPositiveAmount();

    /// @notice Thrown when a reentrancy attempt is detected
    error Reentrancy();

    /// @notice Thrown when an ETH transfer fails
    error TransferFailed(address to, uint256 amount);

    /// @notice Thrown when the provided constructor limits are invalid (e.g., withdraw limit > bank cap)
    error InvalidLimits(uint256 bankCap, uint256 withdrawLimit);

    /*//////////////////////////////////////////////////////////////////////////
                                      EVENTS
    /////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a user deposits ETH into their vault
    event DepositMade(address indexed account, uint256 amount, uint256 newBalance);

    /// @notice Emitted when a user withdraws ETH from their vault
    event WithdrawalMade(address indexed account, uint256 amount, uint256 newBalance);

    /*//////////////////////////////////////////////////////////////////////////
                                    STATE VARIABLES
    /////////////////////////////////////////////////////////////////////////*/

    /// @notice The global maximum deposit capacity of the bank (immutable)
    uint256 public immutable i_bankCap;

    /// @notice The per-transaction limit for withdrawals (immutable)
    uint256 public immutable i_withdrawLimit;

    /// @notice Mapping of user balances (personal vaults)
    mapping(address owner => uint256 amount) private s_balances;

    /// @notice Reentrancy guard: 0 = not entered, 1 = entered
    uint8 private s_locked = 0; 

    uint256 private s_depositCount;
    uint256 private s_withdrawCount;

    /*//////////////////////////////////////////////////////////////////////////
                                      MODIFIERS
    /////////////////////////////////////////////////////////////////////////*/

    /// @notice Prevents reentrancy in critical functions
    modifier nonReentrant() {
        if (s_locked == 1) revert Reentrancy();
        s_locked = 1;
        _;
        s_locked = 0;
    }

    /// @notice Validates that the amount is positive (greater than zero)
    modifier positiveAmount(uint256 amount) {
        if (amount == 0) revert NotPositiveAmount();
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     CONSTRUCTOR
    /////////////////////////////////////////////////////////////////////////*/

    /// @param _bankCap Global deposit limit for the contract (in wei)
    /// @param _withdrawLimit Maximum per-transaction limit for withdrawals (in wei)
    constructor(uint256 _bankCap, uint256 _withdrawLimit) {
        if (_withdrawLimit > _bankCap) revert InvalidLimits(_bankCap, _withdrawLimit);
        
        i_bankCap = _bankCap;
        i_withdrawLimit = _withdrawLimit;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   EXTERNAL FUNCTIONS
    /////////////////////////////////////////////////////////////////////////*/

    /// @notice Deposits ETH into the sender's vault
    /// @dev Follows **Checks-Effects-Interactions (CEI)**: validation, state update, and event emission.
    /// @dev Reverts with `ExceedsBankCap` if the deposit exceeds `i_bankCap`.
    function deposit() external payable positiveAmount(msg.value) {
        uint256 currentBalance = address(this).balance;
        if (currentBalance > i_bankCap) {
            revert ExceedsBankCap(currentBalance, i_bankCap);
        }

        s_balances[msg.sender] += msg.value;
        s_depositCount += 1; 
        emit DepositMade(msg.sender, msg.value, s_balances[msg.sender]);
    }

    /// @notice Withdraws ETH from the sender's vault up to the per-transaction limit
    /// @param _amount Amount in wei to withdraw
    /// @dev Applies **Checks-Effects-Interactions (CEI)** pattern and uses **`nonReentrant`** guard.
    function withdraw(uint256 _amount) external nonReentrant positiveAmount(_amount) {
        if (_amount > i_withdrawLimit) revert ExceedsWithdrawLimit(_amount, i_withdrawLimit);

        uint256 bal = s_balances[msg.sender];
        if (_amount > bal) revert InsufficientBalance(msg.sender, bal, _amount);

        s_balances[msg.sender] = bal - _amount;
        s_withdrawCount += 1; 

        _safeTransfer(msg.sender, _amount);

        emit WithdrawalMade(msg.sender, _amount, s_balances[msg.sender]);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    PRIVATE FUNCTIONS
    /////////////////////////////////////////////////////////////////////////*/

    /// @notice Performs a safe ETH transfer using `call`
    /// @param _to Destination address
    /// @param _amount Amount in wei
    function _safeTransfer(address _to, uint256 _amount) private {
        (bool ok, ) = payable(_to).call{value: _amount, gas: 23000}("");
        if (!ok) revert TransferFailed(_to, _amount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     VIEW FUNCTIONS
    /////////////////////////////////////////////////////////////////////////*/

    /// @notice Gets the vault balance of an account
    /// @param _account User's address
    /// @return Balance in wei
    function getBalance(address _account) external view returns (uint256) {
        return s_balances[_account];
    }

    /// @notice Returns the total number of deposits recorded
    function getDepositCount() external view returns (uint256) {
        return s_depositCount;
    }

    /// @notice Returns the total number of withdrawals recorded
    function getWithdrawCount() external view returns (uint256) {
        return s_withdrawCount;
    }

    /// @notice Returns the remaining capacity of the bank (bankCap - contractBalance)
    function getRemainingCap() external view returns (uint256) {
        uint256 current = address(this).balance;
        if (current >= i_bankCap) return 0;
        return i_bankCap - current;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   ETH RECEPTION
    /////////////////////////////////////////////////////////////////////////*/

    /// @notice Used to receive ETH directly via a simple `transfer` or `send`
    /// @dev Implements the core **Checks-Effects-Interactions (CEI)** logic for deposit.
    receive() external payable {
        if (msg.value == 0) revert NotPositiveAmount();
        uint256 newTotal = address(this).balance;
        if (newTotal > i_bankCap) {
            revert ExceedsBankCap(newTotal, i_bankCap);
        }

        s_balances[msg.sender] += msg.value;
        s_depositCount += 1;

        emit DepositMade(msg.sender, msg.value, s_balances[msg.sender]);
    }

    /// @notice Fallback function to handle calls with unknown calldata
    /// @dev If ETH is sent, it also processes it as a deposit, using CEI and checks.
    fallback() external payable {
        if (msg.value > 0) {
            uint256 newTotal = address(this).balance;
            if (newTotal > i_bankCap) {
                revert ExceedsBankCap(newTotal, i_bankCap);
            }
            
            s_balances[msg.sender] += msg.value;
            s_depositCount += 1;
            
            emit DepositMade(msg.sender, msg.value, s_balances[msg.sender]);
        }
    }
}