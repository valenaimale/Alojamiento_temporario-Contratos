# HayLugar: contrato de pagos

El contrato inteligente `PasarelaPago` cobra en **ETH de prueba** las reservas de HayLugar (Alojamiento temporario, Seminario UNLu) y **retiene el dinero** hasta que el huésped ingresa o cancela.

- **Red:** Base Sepolia (chain id 84532).
- **Hecho con:** [Foundry](https://getfoundry.sh) y [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/5.x/) v5.7.0.
- **Repos relacionados:** el backend (PHP), que verifica los pagos leyendo el evento `PagoRealizado`, y el frontend, que llama a `pagarSena` y `pagarSaldo` desde MetaMask.

## Estado

| Versión | Qué tiene |
|---|---|
| 1 (actual) | `pagarSena(reservaId)` y `pagarSaldo(reservaId)`, con el evento `PagoRealizado` |
| 2 (próxima) | `devolver` y `liquidar`, solo para la billetera de la plataforma |

## Funciones

| Función | Quién la llama | Qué hace |
|---|---|---|
| `pagarSena(uint256 reservaId)` *payable* | El huésped | Anota al huésped de la reserva y retiene el ETH. Una sola vez por reserva |
| `pagarSaldo(uint256 reservaId)` *payable* | Cualquier billetera | Retiene el ETH del saldo. Solo si ya hay seña, y una sola vez |
| `reservas(uint256 reservaId)` *view* | Cualquiera | Devuelve el huésped, lo depositado en wei y si el saldo está pago |

El contrato **no conoce los precios**: están en pesos en la base de datos del back. El back controla en el evento que el monto pagado sea el de la reserva antes de confirmarla.

### Evento

```solidity
event PagoRealizado(uint256 indexed reservaId, address indexed pagador, uint256 monto, Tipo tipo);
// tipo: 0 = seña, 1 = saldo (en el ABI es un uint8). monto en wei.
```

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

## Seguridad

- La clave privada de la billetera de la plataforma **nunca** va al repo: se usa desde un archivo `.env`, que está en el `.gitignore`.
