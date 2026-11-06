// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {PasarelaPago} from "../src/PasarelaPago.sol";

/// @notice Despliega PasarelaPago con la billetera de la plataforma como dueña.
/// @dev Uso (ver el README):
///        forge script script/Desplegar.s.sol --rpc-url base_sepolia --account plataforma --broadcast --verify
///      La dirección de la plataforma sale de la variable PLATAFORMA_DIRECCION (archivo .env, fuera del repo).
///      La clave privada NUNCA pasa por acá: la usa forge desde el keystore cifrado (--account).
contract Desplegar is Script {
    /// @notice Base Sepolia, la red de prueba elegida.
    uint256 private constant BASE_SEPOLIA = 84532;
    /// @notice Anvil, la red local de Foundry, para ensayar.
    uint256 private constant ANVIL = 31337;

    /// @notice La red no es una de prueba: el script se niega a desplegar (por ejemplo, en la red principal).
    error RedNoPermitida(uint256 chainId);

    /// @notice Controla la red, despliega el contrato y muestra su dirección.
    function run() external returns (PasarelaPago pasarela) {
        if (block.chainid != BASE_SEPOLIA && block.chainid != ANVIL) revert RedNoPermitida(block.chainid);
        address plataforma = vm.envAddress("PLATAFORMA_DIRECCION");

        vm.startBroadcast();
        pasarela = new PasarelaPago(plataforma);
        vm.stopBroadcast();

        console.log("Red (chain id):", block.chainid);
        console.log("PasarelaPago desplegado en:", address(pasarela));
        console.log("Duena (plataforma):", pasarela.owner());
    }
}
