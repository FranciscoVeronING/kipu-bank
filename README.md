# KipuBank

**Autor:** FranciscoVeron  
**Propósito:** Proyecto examen Módulo 2 — contrato inteligente en Solidity que permite depósitos y retiros con límites.

---

## Descripción
KipuBank es una bóveda personal on-chain donde cada usuario puede depositar ETH en su propia cuenta interna. El contrato:
- Permite depositar ETH (función `deposit()` o enviar ETH directamente).
- Permite retirar ETH con un **límite máximo por transacción** (`withdrawLimit`) definido en el despliegue.
- Tiene un **límite global de depósitos** (`bankCap`) fijado en el despliegue.
- Emite eventos en depósitos y retiros.
- Usa errores personalizados y patrón checks-effects-interactions.
- Guarda contadores de depósitos y retiros para auditoría.

---

## Archivos clave
- `contracts/KipuBank.sol` — Contrato principal.
- `README.md` — Este documento.


---

## Parametrización
Al desplegar, debes pasar dos parámetros (en wei):
1. `_bankCap` — límite global del banco (p. ej. `100 ether` -> `100 * 1e18`)
2. `_withdrawLimit` — límite por transacción para retiros (p. ej. `1 ether` -> `1 * 1e18`)

---

## Ejemplo de despliegue (Hardhat + ethers)
1. Instalo dependencias:
```bash
npm init -y
npm i --save-dev hardhat @nomiclabs/hardhat-ethers ethers
npx hardhat
