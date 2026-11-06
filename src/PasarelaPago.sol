// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title PasarelaPago
/// @notice Cobra en ETH de prueba las reservas de HayLugar (Alojamiento temporario) y retiene el dinero (escrow)
///         hasta que el huésped ingresa (liquidación al propietario y al administrador) o cancela (devolución).
/// @dev Versión 1: solo los pagos del huésped (seña y saldo). `devolver` y `liquidar`, que puede llamar únicamente
///      la billetera de la plataforma (la `owner`), llegan en la versión 2.
///      El contrato NO conoce los precios: están en pesos en la base de datos. El back controla, con el evento
///      `PagoRealizado`, que el monto pagado sea el de la reserva antes de confirmarla.
contract PasarelaPago is Ownable {
    /// @notice Qué se pagó. En el ABI viaja como uint8: 0 = seña, 1 = saldo.
    enum Tipo {
        Sena,
        Saldo
    }

    /// @notice Lo que el contrato sabe de cada reserva.
    /// @param huesped La billetera que pagó la seña. Es la única a la que se le va a poder devolver.
    /// @param depositado Todo el ETH (en wei) que entró para esta reserva: seña más saldo.
    /// @param saldoPagado Si ya se pagó el saldo (se paga una sola vez).
    struct Reserva {
        address huesped;
        uint256 depositado;
        bool saldoPagado;
    }

    /// @notice Las reservas, por el mismo id que tienen en la base de datos del back.
    mapping(uint256 reservaId => Reserva) public reservas;

    /// @notice Se emite en cada pago. Es lo que lee el back (eth_getTransactionReceipt) para confirmar la reserva.
    /// @param reservaId El id de la reserva en la base de datos.
    /// @param pagador La billetera que pagó.
    /// @param monto Lo que pagó, en wei.
    /// @param tipo 0 = seña, 1 = saldo.
    event PagoRealizado(uint256 indexed reservaId, address indexed pagador, uint256 monto, Tipo tipo);

    /// @notice El pago vino sin ETH.
    error MontoInvalido();
    /// @notice Esa reserva ya tiene la seña pagada.
    error SenaYaPagada(uint256 reservaId);
    /// @notice Se quiso pagar el saldo de una reserva sin seña.
    error SinSena(uint256 reservaId);
    /// @notice Esa reserva ya tiene el saldo pagado.
    error SaldoYaPagado(uint256 reservaId);

    /// @notice Despliega el contrato con la billetera de la plataforma como dueña.
    /// @param plataforma La billetera que va a poder devolver y liquidar (la que usa el back).
    constructor(address plataforma) Ownable(plataforma) {}

    /// @notice El huésped paga la seña de su reserva, mandando el ETH junto con la llamada.
    /// @dev Queda anotado como el huésped de la reserva: a esa billetera se le devuelve si cancela.
    /// @param reservaId El id de la reserva en la base de datos.
    function pagarSena(uint256 reservaId) external payable {
        if (msg.value == 0) revert MontoInvalido();
        Reserva storage reserva = reservas[reservaId];
        if (reserva.huesped != address(0)) revert SenaYaPagada(reservaId);

        reserva.huesped = msg.sender;
        reserva.depositado += msg.value;

        emit PagoRealizado(reservaId, msg.sender, msg.value, Tipo.Sena);
    }

    /// @notice Se paga el saldo de una reserva que ya tiene la seña. Lo puede pagar cualquier billetera.
    /// @param reservaId El id de la reserva en la base de datos.
    function pagarSaldo(uint256 reservaId) external payable {
        if (msg.value == 0) revert MontoInvalido();
        Reserva storage reserva = reservas[reservaId];
        if (reserva.huesped == address(0)) revert SinSena(reservaId);
        if (reserva.saldoPagado) revert SaldoYaPagado(reservaId);

        reserva.saldoPagado = true;
        reserva.depositado += msg.value;

        emit PagoRealizado(reservaId, msg.sender, msg.value, Tipo.Saldo);
    }
}
