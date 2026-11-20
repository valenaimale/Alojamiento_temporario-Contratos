// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PasarelaPago
/// @notice Cobra en ETH de prueba las reservas de HayLugar (Alojamiento temporario) y retiene el dinero (escrow)
///         hasta que el huésped ingresa (liquidación al propietario y al administrador) o cancela (devolución).
/// @dev El contrato NO conoce los precios ni la política de cancelación: están en pesos en la base de datos.
///      El back controla, con el evento `PagoRealizado`, que el monto pagado sea el de la reserva, y calcula cuánto
///      devolver y cuánto liquidar. Lo que sí garantiza el contrato, aunque el back se equivoque o le roben la clave:
///        - solo la plataforma (la `owner`) puede sacar ETH, con `devolver` o `liquidar`;
///        - una devolución solo le puede pagar al huésped que pagó la seña de esa reserva;
///        - de una reserva nunca sale más ETH del que entró para ella.
///      Las funciones que mandan ETH siguen el patrón CEI (primero controlar, después anotar, al final mandar)
///      y además tienen `nonReentrant`.
contract PasarelaPago is Ownable, ReentrancyGuard {
    /// @notice Qué se pagó. En el ABI viaja como uint8: 0 = seña, 1 = saldo.
    enum Tipo {
        Sena,
        Saldo
    }

    /// @notice Lo que el contrato sabe de cada reserva.
    /// @param huesped La billetera que pagó la seña. Es la única a la que se le puede devolver.
    /// @param depositado Todo el ETH (en wei) que entró para esta reserva: seña más saldo.
    /// @param liberado Todo el ETH (en wei) que ya salió: devuelto más liquidado. Nunca supera a `depositado`.
    /// @param saldoPagado Si ya se pagó el saldo (se paga una sola vez).
    /// @param devuelta Si ya se hizo la devolución (una sola vez). Después no se aceptan más pagos.
    struct Reserva {
        address huesped;
        uint256 depositado;
        uint256 liberado;
        bool saldoPagado;
        bool devuelta;
    }

    /// @notice Cuántas reservas puede tener como máximo un pago grupal. Pone un techo al gas del bucle.
    uint256 public constant MAXIMO_GRUPO = 10;

    /// @notice Las reservas, por el mismo id que tienen en la base de datos del back.
    mapping(uint256 reservaId => Reserva) public reservas;

    /// @notice Se emite en cada pago. Es lo que lee el back (eth_getTransactionReceipt) para confirmar la reserva.
    /// @param reservaId El id de la reserva en la base de datos.
    /// @param pagador La billetera que pagó.
    /// @param monto Lo que pagó, en wei.
    /// @param tipo 0 = seña, 1 = saldo.
    event PagoRealizado(uint256 indexed reservaId, address indexed pagador, uint256 monto, Tipo tipo);

    /// @notice Se emite cuando la plataforma le devuelve ETH al huésped por una cancelación.
    event Devolucion(uint256 indexed reservaId, address indexed huesped, uint256 monto);

    /// @notice Se emite una vez por cada destinatario de una liquidación (propietario, administrador, plataforma).
    event Liquidacion(uint256 indexed reservaId, address indexed destinatario, uint256 monto);

    /// @notice El pago o la transferencia vino sin monto.
    error MontoInvalido();
    /// @notice Esa reserva ya tiene la seña pagada.
    error SenaYaPagada(uint256 reservaId);
    /// @notice Se quiso pagar el saldo, o devolver, en una reserva sin seña.
    error SinSena(uint256 reservaId);
    /// @notice Esa reserva ya tiene el saldo pagado.
    error SaldoYaPagado(uint256 reservaId);
    /// @notice Esa reserva ya tuvo su devolución: no acepta más pagos ni otra devolución.
    error ReservaDevuelta(uint256 reservaId);
    /// @notice Se quiso devolver a una billetera que no es la que pagó la seña.
    error HuespedIncorrecto(uint256 reservaId, address esperado, address recibido);
    /// @notice Se quiso sacar de una reserva más ETH del que le queda.
    error FondosInsuficientes(uint256 reservaId, uint256 disponible, uint256 pedido);
    /// @notice Las listas de una liquidación o de un pago grupal están vacías, no tienen el mismo largo,
    ///         o el grupo tiene más de MAXIMO_GRUPO reservas.
    error ListasInvalidas();
    /// @notice En un pago grupal, los montos no suman lo que se mandó.
    error SumaIncorrecta(uint256 montos, uint256 enviado);
    /// @notice Un destinatario de la liquidación es la dirección cero.
    error DestinatarioInvalido();
    /// @notice El destinatario no aceptó el ETH (por ejemplo, un contrato sin forma de recibirlo).
    error TransferenciaFallida(address destinatario, uint256 monto);
    /// @notice La plataforma no puede renunciar a ser la dueña: el ETH retenido quedaría trabado para siempre.
    error RenunciaNoPermitida();

    /// @notice Despliega el contrato con la billetera de la plataforma como dueña.
    /// @param plataforma La billetera que va a poder devolver y liquidar (la que usa el back).
    constructor(address plataforma) Ownable(plataforma) {}

    // ---------- Pagos del huésped ----------

    /// @notice El huésped paga la seña de su reserva, mandando el ETH junto con la llamada.
    /// @dev Queda anotado como el huésped de la reserva: a esa billetera se le devuelve si cancela.
    /// @param reservaId El id de la reserva en la base de datos.
    function pagarSena(uint256 reservaId) external payable {
        _anotarSena(reservaId, msg.value);
    }

    /// @notice Se paga el saldo de una reserva que ya tiene la seña. Lo puede pagar cualquier billetera.
    /// @param reservaId El id de la reserva en la base de datos.
    function pagarSaldo(uint256 reservaId) external payable {
        _anotarSaldo(reservaId, msg.value);
    }

    // ---------- Pagos de una reserva grupal ----------
    // Una reserva grupal son varias reservas (una por unidad, cada una de su propietario) que paga un mismo huésped
    // en UNA sola transacción. Después de pagar, cada reserva queda anotada por separado, igual que si se hubiera
    // pagado sola: se devuelve y se liquida unidad por unidad con `devolver` y `liquidar`, sin funciones grupales.

    /// @notice El huésped paga en una sola transacción la seña de todas las reservas de un grupo.
    /// @dev Todo o nada: si alguna reserva ya tiene seña (o un monto es cero), se revierte la transacción entera.
    ///      El huésped queda anotado en cada reserva, así cada unidad se le puede devolver por separado.
    ///      Se emite un `PagoRealizado` por reserva, el mismo evento que en un pago individual.
    /// @param reservaIds Los ids de las reservas del grupo en la base de datos (hasta MAXIMO_GRUPO).
    /// @param montos Lo que corresponde a cada reserva, en wei, en el mismo orden. Tienen que sumar lo que se manda.
    function pagarSenaGrupal(uint256[] calldata reservaIds, uint256[] calldata montos) external payable {
        _controlarGrupo(reservaIds, montos, msg.value);
        for (uint256 i = 0; i < reservaIds.length; i++) {
            _anotarSena(reservaIds[i], montos[i]);
        }
    }

    /// @notice Se paga en una sola transacción el saldo de todas las reservas de un grupo.
    /// @dev Todo o nada, igual que la seña: si alguna no tiene seña, ya tuvo su devolución (se canceló esa unidad)
    ///      o ya tiene el saldo pagado, se revierte entera. Por eso el back manda solo las unidades que siguen vigentes.
    /// @param reservaIds Los ids de las reservas del grupo (hasta MAXIMO_GRUPO).
    /// @param montos El saldo de cada reserva, en wei, en el mismo orden. Tienen que sumar lo que se manda.
    function pagarSaldoGrupal(uint256[] calldata reservaIds, uint256[] calldata montos) external payable {
        _controlarGrupo(reservaIds, montos, msg.value);
        for (uint256 i = 0; i < reservaIds.length; i++) {
            _anotarSaldo(reservaIds[i], montos[i]);
        }
    }

    // ---------- Salidas de ETH (solo la plataforma) ----------

    /// @notice La plataforma le devuelve al huésped lo que no se retiene cuando cancela su reserva.
    /// @dev Una sola vez por reserva: si el back reintenta una devolución que ya había salido, se rechaza.
    ///      Lo retenido queda en el contrato hasta que se liquida al propietario con `liquidar`.
    /// @param reservaId El id de la reserva en la base de datos.
    /// @param huesped La billetera a la que se devuelve. Tiene que ser la que pagó la seña.
    /// @param monto Lo que se devuelve, en wei.
    function devolver(uint256 reservaId, address payable huesped, uint256 monto) external nonReentrant onlyOwner {
        // Controlar
        if (monto == 0) revert MontoInvalido();
        Reserva storage reserva = reservas[reservaId];
        if (reserva.huesped == address(0)) revert SinSena(reservaId);
        if (reserva.devuelta) revert ReservaDevuelta(reservaId);
        if (huesped != reserva.huesped) revert HuespedIncorrecto(reservaId, reserva.huesped, huesped);
        uint256 restante = reserva.depositado - reserva.liberado;
        if (monto > restante) revert FondosInsuficientes(reservaId, restante, monto);

        // Anotar
        reserva.devuelta = true;
        reserva.liberado += monto;
        emit Devolucion(reservaId, huesped, monto);

        // Mandar
        (bool ok,) = huesped.call{value: monto}("");
        if (!ok) revert TransferenciaFallida(huesped, monto);
    }

    /// @notice La plataforma reparte el dinero de una reserva: al propietario, al administrador y su comisión.
    /// @dev Se puede llamar más de una vez por reserva (por ejemplo, para liquidar lo retenido de una cancelación, o
    ///      un saldo que se pagó tarde), pero entre todas las llamadas nunca sale más de lo que entró.
    /// @param reservaId El id de la reserva en la base de datos.
    /// @param destinatarios Las billeteras que cobran.
    /// @param montos Lo que cobra cada una, en wei, en el mismo orden.
    function liquidar(uint256 reservaId, address payable[] calldata destinatarios, uint256[] calldata montos)
        external
        nonReentrant
        onlyOwner
    {
        // Controlar
        uint256 cantidad = destinatarios.length;
        if (cantidad == 0 || cantidad != montos.length) revert ListasInvalidas();
        uint256 total = 0;
        for (uint256 i = 0; i < cantidad; i++) {
            if (destinatarios[i] == address(0)) revert DestinatarioInvalido();
            if (montos[i] == 0) revert MontoInvalido();
            total += montos[i];
        }
        Reserva storage reserva = reservas[reservaId];
        uint256 restante = reserva.depositado - reserva.liberado;
        if (total > restante) revert FondosInsuficientes(reservaId, restante, total);

        // Anotar (los eventos también, antes de mandar nada)
        reserva.liberado += total;
        for (uint256 i = 0; i < cantidad; i++) {
            emit Liquidacion(reservaId, destinatarios[i], montos[i]);
        }

        // Mandar (si alguno no acepta el ETH, se deshace toda la liquidación)
        for (uint256 i = 0; i < cantidad; i++) {
            (bool ok,) = destinatarios[i].call{value: montos[i]}("");
            if (!ok) revert TransferenciaFallida(destinatarios[i], montos[i]);
        }
    }

    // ---------- Consultas ----------

    /// @notice Cuánto ETH (en wei) le queda a una reserva en el contrato: lo que todavía se puede devolver o liquidar.
    /// @param reservaId El id de la reserva en la base de datos.
    function disponible(uint256 reservaId) external view returns (uint256) {
        Reserva storage reserva = reservas[reservaId];
        return reserva.depositado - reserva.liberado;
    }

    // ---------- Internas ----------

    /// @dev Anota la seña de una reserva: la billetera que paga queda como su huésped. La usan el pago individual y
    ///      el grupal, así las dos siguen exactamente las mismas reglas.
    function _anotarSena(uint256 reservaId, uint256 monto) private {
        if (monto == 0) revert MontoInvalido();
        Reserva storage reserva = reservas[reservaId];
        if (reserva.huesped != address(0)) revert SenaYaPagada(reservaId);

        reserva.huesped = msg.sender;
        reserva.depositado += monto;

        emit PagoRealizado(reservaId, msg.sender, monto, Tipo.Sena);
    }

    /// @dev Anota el saldo de una reserva que ya tiene la seña (una sola vez, y nunca después de una devolución).
    function _anotarSaldo(uint256 reservaId, uint256 monto) private {
        if (monto == 0) revert MontoInvalido();
        Reserva storage reserva = reservas[reservaId];
        if (reserva.huesped == address(0)) revert SinSena(reservaId);
        if (reserva.devuelta) revert ReservaDevuelta(reservaId);
        if (reserva.saldoPagado) revert SaldoYaPagado(reservaId);

        reserva.saldoPagado = true;
        reserva.depositado += monto;

        emit PagoRealizado(reservaId, msg.sender, monto, Tipo.Saldo);
    }

    /// @dev Controla las listas de un pago grupal: no vacías, del mismo largo, de hasta MAXIMO_GRUPO reservas, y que
    ///      los montos sumen exactamente lo que se mandó (ni un wei de más queda sin dueño, ni uno de menos).
    function _controlarGrupo(uint256[] calldata reservaIds, uint256[] calldata montos, uint256 enviado) private pure {
        uint256 cantidad = reservaIds.length;
        if (cantidad == 0 || cantidad > MAXIMO_GRUPO || cantidad != montos.length) revert ListasInvalidas();
        uint256 total = 0;
        for (uint256 i = 0; i < cantidad; i++) {
            total += montos[i];
        }
        if (total != enviado) revert SumaIncorrecta(total, enviado);
    }

    // ---------- Seguridad ----------

    /// @notice Anulada a propósito: sin dueña, nadie podría devolver ni liquidar y el ETH quedaría trabado.
    /// @dev Cambiar de billetera sí se puede, con `transferOwnership`.
    function renounceOwnership() public view override onlyOwner {
        revert RenunciaNoPermitida();
    }
}
