// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PasarelaPago} from "../src/PasarelaPago.sol";

/// @notice Tests de los pagos del huésped (versión 1 del contrato): unitarios y fuzz.
/// @dev Cada test arranca con un contrato recién desplegado (setUp) y con billeteras de prueba con ETH (deal).
contract PasarelaPagoTest is Test {
    PasarelaPago private pasarela;

    address private plataforma = makeAddr("plataforma");
    address private juan = makeAddr("juan");
    address private otro = makeAddr("otro");

    uint256 private constant RESERVA = 21;
    uint256 private constant SENA = 0.001 ether;
    uint256 private constant SALDO = 0.004 ether;

    // Lo mismo que declara el contrato, para poder esperarlo con vm.expectEmit
    event PagoRealizado(uint256 indexed reservaId, address indexed pagador, uint256 monto, PasarelaPago.Tipo tipo);

    /// @notice Despliega el contrato con la plataforma como dueña y le da ETH de prueba a los huéspedes.
    function setUp() public {
        pasarela = new PasarelaPago(plataforma);
        vm.deal(juan, 10 ether);
        vm.deal(otro, 10 ether);
    }

    // ---------- Despliegue ----------

    /// @notice La dueña del contrato es la billetera de la plataforma, no la que lo desplegó.
    function test_LaDuenaEsLaPlataforma() public view {
        assertEq(pasarela.owner(), plataforma);
    }

    // ---------- Seña ----------

    /// @notice Pagar la seña anota al huésped y lo depositado, y el ETH queda en el contrato.
    function test_PagarSenaAnotaAlHuespedYRetieneElEth() public {
        vm.prank(juan);
        pasarela.pagarSena{value: SENA}(RESERVA);

        (address huesped, uint256 depositado, bool saldoPagado) = pasarela.reservas(RESERVA);
        assertEq(huesped, juan);
        assertEq(depositado, SENA);
        assertFalse(saldoPagado);
        assertEq(address(pasarela).balance, SENA);
        assertEq(juan.balance, 10 ether - SENA);
    }

    /// @notice Pagar la seña emite PagoRealizado con la reserva, el pagador, el monto y el tipo seña.
    function test_PagarSenaEmiteElEvento() public {
        vm.expectEmit(address(pasarela));
        emit PagoRealizado(RESERVA, juan, SENA, PasarelaPago.Tipo.Sena);

        vm.prank(juan);
        pasarela.pagarSena{value: SENA}(RESERVA);
    }

    /// @notice Una seña sin ETH se rechaza.
    function test_PagarSenaSinEthSeRechaza() public {
        vm.prank(juan);
        vm.expectRevert(PasarelaPago.MontoInvalido.selector);
        pasarela.pagarSena(RESERVA);
    }

    /// @notice La seña de una reserva se paga una sola vez, aunque la intente pagar otra billetera.
    function test_LaSenaNoSePagaDosVeces() public {
        vm.prank(juan);
        pasarela.pagarSena{value: SENA}(RESERVA);

        vm.prank(otro);
        vm.expectRevert(abi.encodeWithSelector(PasarelaPago.SenaYaPagada.selector, RESERVA));
        pasarela.pagarSena{value: SENA}(RESERVA);
    }

    // ---------- Saldo ----------

    /// @notice El saldo no se puede pagar antes que la seña.
    function test_PagarSaldoSinSenaSeRechaza() public {
        vm.prank(juan);
        vm.expectRevert(abi.encodeWithSelector(PasarelaPago.SinSena.selector, RESERVA));
        pasarela.pagarSaldo{value: SALDO}(RESERVA);
    }

    /// @notice Un saldo sin ETH se rechaza.
    function test_PagarSaldoSinEthSeRechaza() public {
        _pagarSena(juan);

        vm.prank(juan);
        vm.expectRevert(PasarelaPago.MontoInvalido.selector);
        pasarela.pagarSaldo(RESERVA);
    }

    /// @notice Pagar el saldo suma lo depositado, lo marca pagado y emite el evento con el tipo saldo.
    function test_PagarSaldoSumaLoDepositadoYEmiteElEvento() public {
        _pagarSena(juan);

        vm.expectEmit(address(pasarela));
        emit PagoRealizado(RESERVA, juan, SALDO, PasarelaPago.Tipo.Saldo);
        vm.prank(juan);
        pasarela.pagarSaldo{value: SALDO}(RESERVA);

        (address huesped, uint256 depositado, bool saldoPagado) = pasarela.reservas(RESERVA);
        assertEq(huesped, juan);
        assertEq(depositado, SENA + SALDO);
        assertTrue(saldoPagado);
        assertEq(address(pasarela).balance, SENA + SALDO);
    }

    /// @notice El saldo lo puede pagar otra billetera, pero el huésped sigue siendo el que pagó la seña.
    function test_ElSaldoLoPuedePagarOtraBilletera() public {
        _pagarSena(juan);

        vm.prank(otro);
        pasarela.pagarSaldo{value: SALDO}(RESERVA);

        (address huesped,,) = pasarela.reservas(RESERVA);
        assertEq(huesped, juan);
    }

    /// @notice El saldo de una reserva se paga una sola vez.
    function test_ElSaldoNoSePagaDosVeces() public {
        _pagarSena(juan);
        vm.prank(juan);
        pasarela.pagarSaldo{value: SALDO}(RESERVA);

        vm.prank(juan);
        vm.expectRevert(abi.encodeWithSelector(PasarelaPago.SaldoYaPagado.selector, RESERVA));
        pasarela.pagarSaldo{value: SALDO}(RESERVA);
    }

    // ---------- ETH suelto ----------

    /// @notice Mandar ETH al contrato sin llamar a una función de pago se rechaza: no quedaría asociado a ninguna reserva.
    function test_EthSinReservaSeRechaza() public {
        vm.prank(juan);
        (bool ok,) = address(pasarela).call{value: SENA}("");
        assertFalse(ok);
        assertEq(address(pasarela).balance, 0);
    }

    // ---------- Fuzz ----------

    /// @notice Para cualquier par de montos, lo depositado es la seña más el saldo, y es lo que tiene el contrato.
    function testFuzz_LoDepositadoEsLaSumaDeLosPagos(uint256 sena, uint256 saldo) public {
        sena = bound(sena, 1, 5 ether);
        saldo = bound(saldo, 1, 5 ether);

        vm.prank(juan);
        pasarela.pagarSena{value: sena}(RESERVA);
        vm.prank(juan);
        pasarela.pagarSaldo{value: saldo}(RESERVA);

        (, uint256 depositado,) = pasarela.reservas(RESERVA);
        assertEq(depositado, sena + saldo);
        assertEq(address(pasarela).balance, sena + saldo);
    }

    /// @notice Para cualquier par de reservas distintas, el pago de una no toca a la otra.
    function testFuzz_LasReservasNoSeMezclan(uint256 reservaA, uint256 reservaB) public {
        vm.assume(reservaA != reservaB);

        vm.prank(juan);
        pasarela.pagarSena{value: SENA}(reservaA);

        (address huesped, uint256 depositado,) = pasarela.reservas(reservaB);
        assertEq(huesped, address(0));
        assertEq(depositado, 0);

        // la otra reserva todavía puede recibir su seña, de otra billetera
        vm.prank(otro);
        pasarela.pagarSena{value: SENA}(reservaB);
        (huesped,,) = pasarela.reservas(reservaB);
        assertEq(huesped, otro);
    }

    // ---------- Ayudas ----------

    /// @notice Paga la seña de RESERVA desde la billetera indicada.
    function _pagarSena(address desde) private {
        vm.prank(desde);
        pasarela.pagarSena{value: SENA}(RESERVA);
    }
}
