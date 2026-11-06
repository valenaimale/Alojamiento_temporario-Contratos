# PasarelaPago: pruebas y seguridad

Cómo se probó el contrato y qué riesgos cubre. El diseño está en [`contrato.md`](contrato.md).

## 1. Resumen

| Control | Herramienta | Resultado |
|---|---|---|
| Tests unitarios | Foundry (`forge test`) | 29 tests, todos pasan |
| Tests *fuzz* | Foundry, 256 casos al azar por test | 3 tests, todos pasan |
| Cobertura | `forge coverage` | **100 %** de líneas, instrucciones, ramas y funciones de `PasarelaPago.sol` |
| Análisis estático | Slither 0.11.6 | **Sin hallazgos High ni Medium** (2 avisos Low/Informational justificados) |
| Formato | `forge fmt --check` | En el CI de GitHub Actions, en cada push y PR |
| Ensayo de punta a punta | Anvil (red local) | Despliegue, pagos, liquidación y devolución con transacciones reales |
| Despliegue real | Base Sepolia | Bytecode idéntico al del repo y código verificado en los exploradores |

Para reproducirlo:

```bash
forge test                       # los 32 tests
forge test --gas-report          # con el gas de cada función
forge coverage                   # la cobertura
slither . --filter-paths "lib|test"
```

## 2. Estrategia de tests

Los tests están en [`test/PasarelaPago.t.sol`](../test/PasarelaPago.t.sol). Cada test arranca con un contrato recién desplegado (`setUp`) y usa billeteras de prueba con nombre (`makeAddr("juan")`) y ETH de prueba (`vm.deal`). Las llamadas se hacen "en nombre de" cada billetera con `vm.prank`, y los fallos y los eventos se esperan con `vm.expectRevert` y `vm.expectEmit`.

### Qué cubre cada grupo

| Grupo | Tests | Qué se comprueba |
|---|---|---|
| Despliegue y dueña | 3 | La dueña es la plataforma (no quien despliega); no puede renunciar; sí puede pasarle el contrato a otra billetera |
| Seña | 4 | Anota al huésped y retiene el ETH; emite el evento con los datos exactos; sin ETH se rechaza; no se paga dos veces |
| Saldo | 6 | Sin seña se rechaza; sin ETH se rechaza; suma lo depositado y emite el evento; lo puede pagar otra billetera; no se paga dos veces ni después de una devolución |
| ETH suelto | 1 | Mandar ETH sin llamar a una función de pago se rechaza |
| Devolver | 7 | Le llega el ETH al huésped y lo retenido queda en el contrato; solo la plataforma; solo al huésped de la seña; no más de lo depositado; una sola vez; sin seña o sin monto se rechaza; si el huésped no acepta el ETH, se deshace |
| Liquidar | 8 | Reparte entre propietaria, administrador y plataforma; liquida lo retenido de una cancelación; en partes sin pasarse; no usa el ETH de otra reserva; solo la plataforma; datos inválidos; si un destinatario rechaza el ETH, nadie cobra; **ataque de reentrada** |
| *Fuzz* | 3 | Ver abajo |

### Tests *fuzz*

Un test *fuzz* recibe parámetros y Foundry lo corre 256 veces con valores al azar, buscando un caso que lo rompa.

| Test | Propiedad que comprueba para cualquier valor |
|---|---|
| `testFuzz_LoDepositadoEsLaSumaDeLosPagos` | Con cualquier seña y saldo, lo depositado es la suma y es exactamente el ETH que tiene el contrato |
| `testFuzz_LasReservasNoSeMezclan` | Con cualquier par de reservas distintas, pagar una no toca a la otra |
| `testFuzz_NuncaSaleMasDeLoQueEntro` | Con cualquier combinación de seña, saldo, devolución y liquidación: si se pide más de lo disponible se rechaza; si no, sale. Siempre `liberado ≤ depositado` y el ETH del contrato es `depositado − liberado` |

### Contratos auxiliares de los tests

- **`RechazaEth`**: un contrato sin forma de recibir ETH. Simula una billetera que rechaza la transferencia, para comprobar que la operación se deshace entera.
- **`PlataformaReentrante`**: una plataforma maliciosa que, al recibir el ETH de una liquidación, intenta volver a entrar a `liquidar` antes de que termine la primera. El test comprueba que `nonReentrant` la frena y el contrato no pierde nada.

## 3. Amenazas y cómo se cubren

| Amenaza | Cómo la frena el contrato | Test |
|---|---|---|
| Alguien que no es la plataforma saca ETH | `onlyOwner` en `devolver` y `liquidar` | `test_SoloLaPlataformaDevuelve`, `test_SoloLaPlataformaLiquida` |
| La plataforma (o quien le robe la clave) se devuelve el ETH a sí misma | `devolver` solo paga a la billetera que pagó la seña | `test_NoSeDevuelveAOtraBilletera` |
| Sacar más ETH del que entró para una reserva | Se controla `monto ≤ depositado − liberado` por reserva | `test_NoSeDevuelveMasDeLoDepositado`, `test_NoSeLiquidaConElEthDeOtraReserva`, `testFuzz_NuncaSaleMasDeLoQueEntro` |
| Devolver dos veces (por ejemplo, un reintento del back) | La reserva queda marcada `devuelta` | `test_LaDevolucionNoSeHaceDosVeces` |
| Reentrada: un destinatario vuelve a llamar al contrato mientras recibe ETH | Patrón CEI (el estado se anota antes de mandar el ETH) y `nonReentrant` de OpenZeppelin | `test_LaReentradaSeFrena` |
| Un destinatario rechaza el ETH y deja una liquidación a medias | Si una transferencia falla, se revierte toda la operación | `test_SiUnDestinatarioNoAceptaElEthNadieCobra`, `test_SiElHuespedNoAceptaElEthLaDevolucionSeDeshace` |
| El ETH queda trabado para siempre | `renounceOwnership` anulada; `transferOwnership` permite cambiar la clave | `test_LaPlataformaNoPuedeRenunciar`, `test_LaPlataformaPuedeCambiarDeBilletera` |
| ETH que no queda asociado a ninguna reserva | El contrato no tiene `receive` ni `fallback`: se rechaza | `test_EthSinReservaSeRechaza` |
| Pagar dos veces la misma seña o saldo | `SenaYaPagada`, `SaldoYaPagado` | `test_LaSenaNoSePagaDosVeces`, `test_ElSaldoNoSePagaDosVeces` |
| Desbordamiento aritmético | Solidity 0.8 revierte ante *overflow* y *underflow* | — (lo garantiza el compilador) |
| Desplegar por error en una red con dinero real | El script de despliegue solo acepta Base Sepolia y Anvil | — |

**Riesgo que queda** (ver [diseño, sección 9](contrato.md#9-limitaciones-y-mejoras-posibles)): con la clave de la plataforma se puede **liquidar** lo disponible hacia cualquier billetera. Es inherente a que la plataforma decida el reparto; se mitigaría con una multisig o roles separados.

## 4. Slither

[Slither](https://github.com/crytic/slither) es un analizador estático de Trail of Bits que busca patrones de vulnerabilidades conocidos.

```bash
python -m venv ~/.venvs/slither
~/.venvs/slither/Scripts/pip install slither-analyzer==0.11.6   # en Linux/macOS: bin/pip
slither . --filter-paths "lib|test"                              # sin las librerías ni los tests
slither . --filter-paths "lib|test" --exclude-low --exclude-informational --exclude-optimization
# → 0 result(s) found
```

### Hallazgo corregido

| Detector | Severidad | Qué pasaba | Corrección |
|---|---|---|---|
| `arbitrary-send-eth` | **High** | El envío de ETH estaba en una función privada auxiliar (`_transferir`), y Slither la analizaba sin ver el `onlyOwner` de quien la llamaba | El envío pasó a estar dentro de `devolver` y `liquidar`, que tienen `onlyOwner` |

### Avisos aceptados

| Detector | Severidad | Por qué se acepta |
|---|---|---|
| `calls-loop` en `liquidar` | Low | Manda ETH a varios destinatarios en un bucle. Si uno lo rechaza, se deshace todo y la plataforma la repite sin él. Los destinatarios los elige solo la plataforma, así que un tercero no puede bloquear liquidaciones ajenas |
| `low-level-calls` en `devolver` y `liquidar` | Informational | `call{value: …}` es la forma recomendada de mandar ETH; se controla el resultado y se revierte si falla |

## 5. Ensayo de punta a punta en Anvil

Antes del despliegue real se ensayó todo el recorrido en **Anvil**, la red local de Foundry, con transacciones de verdad (no simuladas por los tests):

| Paso | Resultado |
|---|---|
| Desplegar con `script/Desplegar.s.sol` | Contrato con la plataforma como dueña |
| El huésped paga la seña de la reserva 21 (0,001 ETH) | `status 1`; el `topics[0]` del evento coincide con el documentado para el back |
| El huésped paga el saldo (0,004 ETH) | El contrato tiene 0,005 ETH |
| El huésped intenta liquidarse el ETH | Rechazado con `OwnableUnauthorizedAccount` |
| La plataforma liquida 0,005 ETH a la propietaria | El contrato queda en 0 |
| Reserva 22: seña, cancelación y devolución del 70 % | `liberado` = 70 % y el 30 % queda retenido para liquidar |

Para repetirlo, ver el [README](../README.md#despliegue).

## 6. Despliegue real

- Antes de mandar nada se **simuló** el despliegue contra Base Sepolia (`forge script` sin `--broadcast`), para confirmar que funcionaba y estimar el costo.
- Después del despliegue se comprobó que el **bytecode en la red es idéntico** al compilado desde el repo (`cast code` contra `forge inspect … deployedBytecode`) y que la dueña es la billetera de la plataforma (`cast call … owner()`).
- El código fuente está **verificado** en basescan, Blockscout y Sourcify (*exact match*): cualquiera puede leerlo y comprobar que es el que corre.
