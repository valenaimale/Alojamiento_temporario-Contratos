# HayLugar: contrato de pagos

El contrato inteligente `PasarelaPago` cobra en **ETH de prueba** las reservas de HayLugar (Alojamiento temporario, Seminario UNLu) y **retiene el dinero** (*escrow*) hasta que el huésped ingresa o cancela.

- **Red:** Base Sepolia (chain id 84532).
- **Hecho con:** [Foundry](https://getfoundry.sh) y [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/5.x/) v5.7.0 (`Ownable`, `ReentrancyGuard`).
- **Repos relacionados:** el backend (PHP), que verifica los pagos leyendo el evento `PagoRealizado` y firma `devolver` y `liquidar` con la billetera de la plataforma, y el frontend, que llama a `pagarSena` y `pagarSaldo` desde MetaMask.
- **Documentación:** [diseño del contrato](docs/contrato.md) (arquitectura, diagramas, decisiones, costos y limitaciones) y [pruebas y seguridad](docs/pruebas-y-seguridad.md) (tests, amenazas cubiertas, Slither y ensayos).
- **ABI:** [`abi/PasarelaPago.json`](abi/PasarelaPago.json). Se regenera con `forge inspect PasarelaPago abi --json > abi/PasarelaPago.json`.

## Despliegue actual

| Dato | Valor |
|---|---|
| Red | Base Sepolia (chain id 84532) |
| Contrato | [`0xF9d86D0e7c3D2520103fD11e64174C9e6BcFc0F4`](https://sepolia.basescan.org/address/0xF9d86D0e7c3D2520103fD11e64174C9e6BcFc0F4) |
| Dueña (billetera de la plataforma) | [`0x734779432891a4E2C9152FdF6eCFFC34825b36B4`](https://sepolia.basescan.org/address/0x734779432891a4E2C9152FdF6eCFFC34825b36B4) |
| Transacción de despliegue | [`0x8950fa26…3c4ec7`](https://sepolia.basescan.org/tx/0x8950fa266242149b817193c638a1a66c2846fda46e899486760ea761633c4ec7) |
| Código verificado | [Blockscout](https://base-sepolia.blockscout.com/address/0xF9d86D0e7c3D2520103fD11e64174C9e6BcFc0F4?tab=contract) y [Sourcify](https://repo.sourcify.dev/84532/0xF9d86D0e7c3D2520103fD11e64174C9e6BcFc0F4) (*exact match*) |
| RPC público | `https://sepolia.base.org` |

El registro completo del despliegue está en [`broadcast/Desplegar.s.sol/84532/run-latest.json`](broadcast/Desplegar.s.sol/84532/run-latest.json).

## El recorrido del dinero

| Momento | Quién firma | Función | Qué pasa con el ETH |
|---|---|---|---|
| El huésped reserva | El huésped (MetaMask) | `pagarSena(reservaId)` | Entra al contrato y queda retenido |
| Antes del ingreso | Cualquier billetera (MetaMask) | `pagarSaldo(reservaId)` | Entra al contrato y queda retenido |
| El huésped ingresa | La plataforma (el back) | `liquidar(reservaId, destinatarios, montos)` | Sale hacia el propietario, el administrador y la comisión de la plataforma |
| El huésped cancela | La plataforma (el back) | `devolver(reservaId, huesped, monto)` | Le vuelve al huésped lo que no se retiene. Lo retenido se liquida después con `liquidar` |

El contrato **no conoce los precios ni la política de cancelación**: están en pesos en la base de datos. El back calcula los montos. Lo que el contrato **garantiza**, aunque el back se equivoque o le roben la clave:

1. Solo la plataforma (la `owner`) puede sacar ETH.
2. Una devolución solo le paga al huésped que pagó la seña de esa reserva, y una sola vez.
3. De una reserva nunca sale más ETH del que entró para ella (`liberado ≤ depositado`). Una reserva no puede usar el ETH de otra.

## Funciones

| Función | Quién | Reglas |
|---|---|---|
| `pagarSena(uint256 reservaId)` *payable* | El huésped | Con ETH. Una sola vez por reserva. Anota al huésped |
| `pagarSaldo(uint256 reservaId)` *payable* | Cualquiera | Con ETH. Solo con seña, sin devolución, y una sola vez |
| `devolver(uint256 reservaId, address huesped, uint256 monto)` | La plataforma | Al huésped de la seña, una sola vez, sin pasarse de lo disponible. Después la reserva no acepta más pagos |
| `liquidar(uint256 reservaId, address[] destinatarios, uint256[] montos)` | La plataforma | Varias veces si hace falta, sin pasarse de lo disponible. Si un destinatario no acepta el ETH, se deshace entera |
| `disponible(uint256 reservaId)` *view* | Cualquiera | Lo que le queda a la reserva en el contrato, en wei |
| `reservas(uint256 reservaId)` *view* | Cualquiera | `huesped`, `depositado`, `liberado`, `saldoPagado`, `devuelta` |
| `transferOwnership(address)` | La plataforma | Cambia la billetera de la plataforma (por ejemplo, si se cambia la clave) |
| `renounceOwnership()` | — | Anulada: sin dueña, el ETH retenido quedaría trabado |

## Para el back: eventos y selectores

Los montos van en **wei** (1 ETH = 10¹⁸ wei). `reservaId` es el id de la reserva en la base de datos.

| Evento | Firma | `topics[0]` |
|---|---|---|
| `PagoRealizado(uint256 indexed reservaId, address indexed pagador, uint256 monto, uint8 tipo)` | tipo: 0 = seña, 1 = saldo | `0x26595ff0dee9598a8c85c81c2b2cac01dcd205cfe43ba94cf10fde1e4598a161` |
| `Devolucion(uint256 indexed reservaId, address indexed huesped, uint256 monto)` | | `0x863d633bde39b1de066d4d8f336fb58af95304f73c18bde19f376fc74ebb18d2` |
| `Liquidacion(uint256 indexed reservaId, address indexed destinatario, uint256 monto)` | Uno por destinatario | `0x16ce0b50c4467a90f7f08794f1f4b069f3a2b20648da22d871bc3ffdb146882e` |

En un log, `topics[1]` es el `reservaId` y `topics[2]` la billetera (los dos con ceros a la izquierda hasta 32 bytes). En `data` van el `monto` y, en `PagoRealizado`, el `tipo`. **El back tiene que controlar además que el log lo emitió la dirección de este contrato**: cualquiera puede desplegar otro contrato con un evento del mismo nombre.

| Función | Selector |
|---|---|
| `pagarSena(uint256)` | `0xa2034aa4` |
| `pagarSaldo(uint256)` | `0x78bcbeeb` |
| `devolver(uint256,address,uint256)` | `0xfd7f3319` |
| `liquidar(uint256,address[],uint256[])` | `0xfc500b5f` |

Los errores del contrato (por ejemplo, `FondosInsuficientes(reservaId, disponible, pedido)`) están en el ABI.

## Cómo usarlo

Hace falta [instalar Foundry](https://getfoundry.sh/introduction/installation). Al clonar, traer también las librerías:

```bash
git clone --recurse-submodules https://github.com/valenaimale/Alojamiento_temporario-Contratos.git
# o, si ya estaba clonado:
git submodule update --init --recursive
```

| Comando | Qué hace |
|---|---|
| `forge build` | Compila los contratos |
| `forge test` | Corre los tests (unitarios y *fuzz*) |
| `forge test -vvv` | Lo mismo, con el detalle de cada falla |
| `forge coverage` | Mide la cobertura de los tests |
| `forge fmt` | Formatea el código (el CI controla que esté formateado) |

## Despliegue

El script [`script/Desplegar.s.sol`](script/Desplegar.s.sol) despliega el contrato con la billetera de la plataforma como dueña. Solo acepta Base Sepolia (84532) o Anvil (31337): se niega a desplegar en una red real. Desplegar en Base Sepolia cuesta unas 0,00002 ETH de prueba.

**Ensayo local con Anvil** (cuentas de prueba con ETH falso; la clave es la cuenta 0 de Anvil, pública y sin valor):

```bash
anvil                                   # en otra terminal
PLATAFORMA_DIRECCION=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
forge script script/Desplegar.s.sol --rpc-url anvil --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

**En Base Sepolia:**

1. Crear la billetera de la plataforma: `cast wallet new`. Guardar la clave privada en un lugar seguro (gestor de contraseñas).
2. Importarla al keystore cifrado de Foundry: `cast wallet import plataforma --interactive` (pide la clave y una contraseña).
3. Cargarle ETH de prueba de Base Sepolia con un faucet.
4. Copiar `.env.example` como `.env` y completar `PLATAFORMA_DIRECCION` y `ETHERSCAN_API_KEY` (una clave gratuita de etherscan.io, que sirve para basescan).
5. Desplegar y verificar el código en basescan (forge lee el `.env` solo):
   ```bash
   forge script script/Desplegar.s.sol --rpc-url base_sepolia --account plataforma --broadcast --verify
   ```
6. La dirección del contrato queda en la salida y en `broadcast/Desplegar.s.sol/84532/run-latest.json`.

Un contrato desplegado **no se puede modificar**. Si hace falta un cambio, se despliega una versión nueva (con otra dirección y sin las reservas de la anterior) y se actualiza la dirección en el back y en el front.

## Calidad y seguridad

- **Tests:** 32, con 3 *fuzz* de 256 casos cada uno. Incluyen un ataque de reentrada y destinatarios que rechazan el ETH.
- **Cobertura:** 100 % de líneas, instrucciones, ramas y funciones de `PasarelaPago.sol`.
- **Slither** 0.11.6 (`slither . --filter-paths "lib|test"`): **sin hallazgos High ni Medium**. Quedan dos avisos, revisados y aceptados:

| Aviso | Severidad | Por qué se acepta |
|---|---|---|
| `calls-loop` en `liquidar` | Low | Manda ETH a varios destinatarios en un bucle. Si uno lo rechaza, la liquidación entera se deshace (nadie cobra a medias) y la plataforma la puede repetir sin ese destinatario. Los destinatarios los elige solo la plataforma |
| `low-level-calls` en `devolver` y `liquidar` | Informational | `call{value: ...}` es la forma recomendada de mandar ETH (`transfer` limita el gas a 2300 y puede fallar con billeteras inteligentes). Se controla el resultado y se revierte si falla |

- La clave privada de la billetera de la plataforma **nunca** va al repo: se usa desde un archivo `.env`, que está en el `.gitignore`.
