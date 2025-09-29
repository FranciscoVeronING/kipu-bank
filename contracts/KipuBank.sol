// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title KipuBank - Bóveda personal con límites por transacción y límite global
/// @author FranciscoVeron
/// @notice Contrato de ejemplo para el examen del Módulo 2. Permite depositar ETH y retirar sujeto a un límite por transacción.
/// @dev Implementa prácticas básicas de seguridad: errores personalizados, checks-effects-interactions, reentrancy guard simple, NatSpec.
contract KipuBank {
    /*//////////////////////////////////////////////////////////////////////////
                                   ERRORES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Se lanza cuando el depósito excede el límite global del banco
    error Err_ExceedsBankCap(uint256 attempted, uint256 bankCap);

    /// @notice Se lanza cuando la cantidad a retirar supera el saldo del usuario
    error Err_InsufficientBalance(address account, uint256 balance, uint256 requested);

    /// @notice Se lanza cuando la cantidad a retirar excede el límite por transacción
    error Err_ExceedsWithdrawLimit(uint256 requested, uint256 withdrawLimit);

    /// @notice Se lanza cuando se intenta depositar 0 o una cantidad inválida
    error Err_NotPositiveDeposit();

    /// @notice Se lanza en caso de reentrada detectada
    error Err_Reentrancy();

    /// @notice Se lanza cuando la transferencia falla
    error Err_TransferFailed(address to, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                                  EVENTOS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Emitido cuando un usuario deposita ETH en su bóveda
    event DepositMade(address indexed account, uint256 amount, uint256 newBalance);

    /// @notice Emitido cuando un usuario retira ETH de su bóveda
    event WithdrawalMade(address indexed account, uint256 amount, uint256 newBalance);

    /*//////////////////////////////////////////////////////////////////////////
                               VARIABLES DE ESTADO
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Límite global máximo de depósitos del banco (inmutable, fijado en constructor)
    uint256 public immutable i_bankCap;

    /// @notice Límite por transacción para retiros (inmutable, fijado en constructor)
    uint256 public immutable i_withdrawLimit;

    /// @notice Mapeo de saldos por usuario (balanza de las bóvedas personales)
    mapping(address owner => uint256 amount) private s_balances;

    /// @notice Número total de depósitos exitosos registrados
    uint256 private depositCount;
 
    /// @notice Número total de retiros exitosos registrados
    uint256 private withdrawCount;

    /// @notice Reentrancy guard: 0 = not entered, 1 = entered
    uint8 private locked = 0;

    /*//////////////////////////////////////////////////////////////////////////
                                   MODIFICADORES
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Previene reentradas en funciones críticas
    modifier nonReentrant() {
        if (locked == 1) revert Err_Reentrancy();
        locked = 1;
        _;
        locked = 0;
    }

    /// @notice Valida que la cantidad sea positiva (mayor a cero)
    modifier positiveAmount(uint256 amount) {
        if (amount == 0) revert Err_NotPositiveDeposit();
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @param _bankCap Límite global de depósitos que acepta el contrato (en wei)
    /// @param _withdrawLimit Límite máximo por transacción para retiros (en wei)
    constructor(uint256 _bankCap, uint256 _withdrawLimit) {
        i_bankCap = _bankCap;
        i_withdrawLimit = _withdrawLimit;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                 FUNCIONES EXTERNAS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Deposita ETH en la bóveda del emisor de la transacción
    /// @dev Sigue checks-effects-interactions: valida, actualiza estado y emite evento. Usa `msg.value`.
    /// @dev Revertirá con Err_ExceedsBankCap si el depósito excede bankCap.
    function deposit() external payable positiveAmount(msg.value) {
        uint256 newTotal = address(this).balance;
        // Como balance del contrato incluye el msg.value ya ingresado, verifico newTotal <= bankCap
        if (newTotal > i_bankCap) revert Err_ExceedsBankCap(newTotal, i_bankCap);

        // efectos (actualizo saldo del usuario)
        s_balances[msg.sender] += msg.value;
        _incrementDepositCount();

        emit DepositMade(msg.sender, msg.value, s_balances[msg.sender]);
    }

    /// @notice Retira ETH de la bóveda del emisor hasta el límite por transacción
    /// @param _amount Cantidad en wei a retirar
    /// @dev Aplica patrón checks-effects-interactions y usa nonReentrant.
    function withdraw(uint256 _amount) external nonReentrant positiveAmount(_amount) {
        if (_amount > i_withdrawLimit) revert Err_ExceedsWithdrawLimit(_amount, i_withdrawLimit);

        uint256 bal = s_balances[msg.sender];
        if (_amount > bal) revert Err_InsufficientBalance(msg.sender, bal, _amount);

        // effects
        s_balances[msg.sender] = bal - _amount;
        _incrementWithdrawCount();

        // interactions (transfer seguro)
        _safeTransfer(msg.sender, _amount);

        emit WithdrawalMade(msg.sender, _amount, s_balances[msg.sender]);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                  FUNCIONES PRIVADAS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Realiza transferencia segura de ETH usando call
    /// @param _to Dirección destino
    /// @param _amount Cantidad en wei
    /// @dev Función privada para centralizar manejo de transferencias.
    function _safeTransfer(address _to, uint256 _amount) private {
        (bool ok, ) = payable(_to).call{value: _amount, gas: 23000}("");
        if (!ok) revert Err_TransferFailed(_to, _amount);
    }

    /// @notice Incrementa el contador de depósitos (función privada)
    function _incrementDepositCount() private {
        unchecked {
            depositCount += 1;
        }
    }

    /// @notice Incrementa el contador de retiros (función privada)
    function _incrementWithdrawCount() private {
        unchecked {
            withdrawCount += 1;
        }
    }
 
    /*//////////////////////////////////////////////////////////////////////////
                                  FUNCIONES DE VISTA
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Obtiene el saldo de la bóveda de una cuenta
    /// @param _account Dirección del usuario
    /// @return Saldo en wei
    function getBalance(address _account) external view returns (uint256) {
        return s_balances[_account];
    }

    /// @notice Retorna el número total de depósitos registrados
    function getDepositCount() external view returns (uint256) {
        return depositCount;
    }

    /// @notice Retorna el número total de retiros registrados
    function getWithdrawCount() external view returns (uint256) {
        return withdrawCount;
    }

    /// @notice Retorna la capacidad restante del banco (bankCap - balanceContrato)
    function getRemainingCap() external view returns (uint256) {
        uint256 current = address(this).balance;
        if (current >= i_bankCap) return 0;
        return i_bankCap - current;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                 RECEPCIÓN DE ETH
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Fallback para recibir ETH directamente; redirijo a deposit()
    receive() external payable {
        // Llamo a deposit() para reutilizar validaciones y efectos (no es external-call, es interno)
        // Nota: deposit() es external. Para evitar reentradas y doble contabilización, replico mínima lógica.
        uint256 newTotal = address(this).balance;
        if (newTotal > i_bankCap) revert Err_ExceedsBankCap(newTotal, i_bankCap);
        if (msg.value == 0) revert Err_NotPositiveDeposit();

        s_balances[msg.sender] += msg.value;
        _incrementDepositCount();
        emit DepositMade(msg.sender, msg.value, s_balances[msg.sender]);
    }

    fallback() external payable {
        // si envían calldata desconocida con ETH, también lo trato como depósito
        if (msg.value > 0) {
            uint256 newTotal = address(this).balance;
            if (newTotal > i_bankCap) revert Err_ExceedsBankCap(newTotal, i_bankCap);
            s_balances[msg.sender] += msg.value;
            _incrementDepositCount();
            emit DepositMade(msg.sender, msg.value, s_balances[msg.sender]);
        }
    }
}
