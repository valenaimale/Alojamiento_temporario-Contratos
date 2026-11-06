// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PasarelaPago} from "../src/PasarelaPago.sol";

/// @notice Un destinatario que no acepta ETH (por ejemplo, un contrato sin `receive`).
contract RechazaEth {}

/// @notice Una plataforma maliciosa: cuando recibe ETH de una liquidación, intenta liquidar de nuevo
///         la misma reserva antes de que termine la primera (ataque de reentrada).
contract PlataformaReentrante {
    PasarelaPago public pasarela;
    uint256 public reservaId;

    /// @notice Guarda el contrato y la reserva que va a atacar.
    function preparar(PasarelaPago pasarela_, uint256 reservaId_) external {
        pasarela = pasarela_;
        reservaId = reservaId_;
    }

    /// @notice Liquida la reserva pagándose a sí misma: esto dispara el `receive` de abajo.
    function liquidarseA(uint256 monto) external {
        address payable[] memory destinatarios = new address payable[](1);
        destinatarios[0] = payable(address(this));
        uint256[] memory montos = new uint256[](1);
        montos[0] = monto;
        pasarela.liquidar(reservaId, destinatarios, montos);
    }

    /// @notice Al recibir el ETH, vuelve a entrar a `liquidar`. `nonReentrant` lo tiene que impedir.
    receive() external payable {
        this.liquidarseA(msg.value);
    }
}

/// @notice Tests de PasarelaPago: unitarios y fuzz.
/// @dev Cada test arranca con un contrato recién desplegado (setUp) y con billeteras de prueba con ETH (deal).
contract PasarelaPagoTest is Test {
    PasarelaPago private pasarela;

    address private plataforma = makeAddr("plataforma");
    address payable private juan = payable(makeAddr("juan"));
    address payable private otro = payable(makeAddr("otro"));
    address payable private propietaria = payable(makeAddr("propietaria"));
    address payable private administrador = payable(makeAddr("administrador"));

    uint256 private constant RESERVA = 21;
    uint256 private constant SENA = 0.001 ether;
    uint256 private constant SALDO = 0.004 ether;

    // Los mismos eventos que declara el contrato, para poder esperarlos con vm.expectEmit
    event PagoRealizado(uint256 indexed reservaId, address indexed pagador, uint256 monto, PasarelaPago.Tipo tipo);
    event Devolucion(uint256 indexed reservaId, address indexed huesped, uint256 monto);
    event Liquidacion(uint256 indexed reservaId, address indexed destinatario, uint256 monto);

    /// @notice Despliega el contrato con la plataforma como dueña y le da ETH de prueba a los huéspedes.
    function setUp() public {
        pasarela = new PasarelaPago(plataforma);
        vm.deal(juan, 10 ether);
        vm.deal(otro, 10 ether);
    }

    // ---------- Despliegue y dueña ----------

    /// @notice La dueña del contrato es la billetera de la plataforma, no la que lo desplegó.
    function test_LaDuenaEsLaPlataforma() public view {
        assertEq(pasarela.owner(), plataforma);
    }

    /// @notice La plataforma no puede renunciar a ser la dueña: el ETH quedaría trabado.
    function test_LaPlataformaNoPuedeRenunciar() public {
        vm.prank(plataforma);
        vm.expectRevert(PasarelaPago.RenunciaNoPermitida.selector);
        pasarela.renounceOwnership();
        assertEq(pasarela.owner(), plataforma);
    }

    /// @notice La plataforma sí puede pasarle el contrato a otra billetera (por ejemplo, si cambia la clave).
    function test_LaPlataformaPuedeCambiarDeBilletera() public {
        address nueva = makeAddr("nueva");
        vm.prank(plataforma);
        pasarela.transferOwnership(nueva);
        assertEq(pasarela.owner(), nueva);
    }

    // ---------- Seña ----------

    /// @notice Pagar la seña anota al huésped y lo depositado, y el ETH queda en el contrato.
    function test_PagarSenaAnotaAlHuespedYRetieneElEth() public {
        _pagarSena();

        PasarelaPago.Reserva memory reserva = _reserva(RESERVA);
        assertEq(reserva.huesped, juan);
        assertEq(reserva.depositado, SENA);
        assertEq(reserva.liberado, 0);
        assertFalse(reserva.saldoPagado);
        assertFalse(reserva.devuelta);
        assertEq(address(pasarela).balance, SENA);
        assertEq(juan.balance, 10 ether - SENA);
        assertEq(pasarela.disponible(RESERVA), SENA);
    }

    /// @notice Pagar la seña emite PagoRealizado con la reserva, el pagador, el monto y el tipo seña.
    function test_PagarSenaEmiteElEvento() public {
        vm.expectEmit(address(pasarela));
        emit PagoRealizado(RESERVA, juan, SENA, PasarelaPago.Tipo.Sena);
        _pagarSena();
    }

    /// @notice Una seña sin ETH se rechaza.
    function test_PagarSenaSinEthSeRechaza() public {
        vm.prank(juan);
        vm.expectRevert(PasarelaPago.MontoInvalido.selector);
        pasarela.pagarSena(RESERVA);
    }

    /// @notice La seña de una reserva se paga una sola vez, aunque la intente pagar otra billetera.
    function test_LaSenaNoSePagaDosVeces() public {
        _pagarSena();

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
        _pagarSena();

        vm.prank(juan);
        vm.expectRevert(PasarelaPago.MontoInvalido.selector);
        pasarela.pagarSaldo(RESERVA);
    }

    /// @notice Pagar el saldo suma lo depositado, lo marca pagado y emite el evento con el tipo saldo.
    function test_PagarSaldoSumaLoDepositadoYEmiteElEvento() public {
        _pagarSena();

        vm.expectEmit(address(pasarela));
        emit PagoRealizado(RESERVA, juan, SALDO, PasarelaPago.Tipo.Saldo);
        _pagarSaldo();

        PasarelaPago.Reserva memory reserva = _reserva(RESERVA);
        assertEq(reserva.huesped, juan);
        assertEq(reserva.depositado, SENA + SALDO);
        assertTrue(reserva.saldoPagado);
        assertEq(address(pasarela).balance, SENA + SALDO);
    }

    /// @notice El saldo lo puede pagar otra billetera, pero el huésped sigue siendo el que pagó la seña.
    function test_ElSaldoLoPuedePagarOtraBilletera() public {
        _pagarSena();

        vm.prank(otro);
        pasarela.pagarSaldo{value: SALDO}(RESERVA);

        assertEq(_reserva(RESERVA).huesped, juan);
    }

    /// @notice El saldo de una reserva se paga una sola vez.
    function test_ElSaldoNoSePagaDosVeces() public {
        _pagarSena();
        _pagarSaldo();

        vm.prank(juan);
        vm.expectRevert(abi.encodeWithSelector(PasarelaPago.SaldoYaPagado.selector, RESERVA));
        pasarela.pagarSaldo{value: SALDO}(RESERVA);
    }

    /// @notice Después de la devolución (la reserva se canceló) no se puede pagar el saldo.
    function test_NoSePagaElSaldoDeUnaReservaDevuelta() public {
        _pagarSena();
        _devolver(SENA / 2);

        vm.prank(juan);
        vm.expectRevert(abi.encodeWithSelector(PasarelaPago.ReservaDevuelta.selector, RESERVA));
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

    // ---------- Devolver ----------

    /// @notice Devolver le manda el ETH al huésped, lo anota, emite el evento y lo retenido queda en el contrato.
    function test_DevolverLeMandaElEthAlHuesped() public {
        _pagarSena();
        uint256 retenido = SENA * 30 / 100;
        uint256 devuelto = SENA - retenido;
        uint256 saldoAntes = juan.balance;

        vm.expectEmit(address(pasarela));
        emit Devolucion(RESERVA, juan, devuelto);
        _devolver(devuelto);

        assertEq(juan.balance, saldoAntes + devuelto);
        assertEq(address(pasarela).balance, retenido);
        assertEq(pasarela.disponible(RESERVA), retenido);
        PasarelaPago.Reserva memory reserva = _reserva(RESERVA);
        assertTrue(reserva.devuelta);
        assertEq(reserva.liberado, devuelto);
    }

    /// @notice Solo la plataforma puede devolver: ni el huésped ni nadie más.
    function test_SoloLaPlataformaDevuelve() public {
        _pagarSena();

        vm.prank(juan);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, juan));
        pasarela.devolver(RESERVA, juan, SENA);
    }

    /// @notice No se puede devolver a una billetera que no pagó la seña, aunque lo pida la plataforma.
    function test_NoSeDevuelveAOtraBilletera() public {
        _pagarSena();

        vm.prank(plataforma);
        vm.expectRevert(abi.encodeWithSelector(PasarelaPago.HuespedIncorrecto.selector, RESERVA, juan, otro));
        pasarela.devolver(RESERVA, otro, SENA);
    }

    /// @notice No se puede devolver más de lo que entró para la reserva.
    function test_NoSeDevuelveMasDeLoDepositado() public {
        _pagarSena();

        vm.prank(plataforma);
        vm.expectRevert(abi.encodeWithSelector(PasarelaPago.FondosInsuficientes.selector, RESERVA, SENA, SENA + 1));
        pasarela.devolver(RESERVA, juan, SENA + 1);
    }

    /// @notice La devolución se hace una sola vez: un reintento de algo que ya salió se rechaza.
    function test_LaDevolucionNoSeHaceDosVeces() public {
        _pagarSena();
        _devolver(SENA / 2);

        vm.prank(plataforma);
        vm.expectRevert(abi.encodeWithSelector(PasarelaPago.ReservaDevuelta.selector, RESERVA));
        pasarela.devolver(RESERVA, juan, 1);
    }

    /// @notice No se devuelve en una reserva sin seña ni con monto cero.
    function test_DevolverSinSenaOSinMontoSeRechaza() public {
        vm.startPrank(plataforma);
        vm.expectRevert(abi.encodeWithSelector(PasarelaPago.SinSena.selector, RESERVA));
        pasarela.devolver(RESERVA, juan, 1);

        vm.expectRevert(PasarelaPago.MontoInvalido.selector);
        pasarela.devolver(RESERVA, juan, 0);
        vm.stopPrank();
    }

    /// @notice Si la billetera del huésped no acepta el ETH, la devolución se deshace entera.
    function test_SiElHuespedNoAceptaElEthLaDevolucionSeDeshace() public {
        address payable rechaza = payable(address(new RechazaEth()));
        vm.deal(rechaza, 1 ether);
        vm.prank(rechaza);
        pasarela.pagarSena{value: SENA}(RESERVA);

        vm.prank(plataforma);
        vm.expectRevert(abi.encodeWithSelector(PasarelaPago.TransferenciaFallida.selector, rechaza, SENA));
        pasarela.devolver(RESERVA, rechaza, SENA);

        assertFalse(_reserva(RESERVA).devuelta);
        assertEq(pasarela.disponible(RESERVA), SENA);
    }

    // ---------- Liquidar ----------

    /// @notice Liquidar reparte el ETH entre los destinatarios, emite un evento por cada uno y lo anota.
    function test_LiquidarRepartePropietariaAdministradorYPlataforma() public {
        _pagarSena();
        _pagarSaldo();
        uint256 total = SENA + SALDO;
        uint256 comisionPlataforma = total * 75 / 1000;
        uint256 comisionAdministrador = total / 10;
        uint256 paraPropietaria = total - comisionPlataforma - comisionAdministrador;

        address payable[] memory destinatarios = new address payable[](3);
        destinatarios[0] = propietaria;
        destinatarios[1] = administrador;
        destinatarios[2] = payable(plataforma);
        uint256[] memory montos = new uint256[](3);
        montos[0] = paraPropietaria;
        montos[1] = comisionAdministrador;
        montos[2] = comisionPlataforma;

        vm.expectEmit(address(pasarela));
        emit Liquidacion(RESERVA, propietaria, paraPropietaria);
        vm.expectEmit(address(pasarela));
        emit Liquidacion(RESERVA, administrador, comisionAdministrador);
        vm.expectEmit(address(pasarela));
        emit Liquidacion(RESERVA, plataforma, comisionPlataforma);
        vm.prank(plataforma);
        pasarela.liquidar(RESERVA, destinatarios, montos);

        assertEq(propietaria.balance, paraPropietaria);
        assertEq(administrador.balance, comisionAdministrador);
        assertEq(plataforma.balance, comisionPlataforma);
        assertEq(address(pasarela).balance, 0);
        assertEq(pasarela.disponible(RESERVA), 0);
    }

    /// @notice Después de una devolución, lo retenido se le puede liquidar a la propietaria.
    function test_LoRetenidoDeUnaCancelacionSeLiquida() public {
        _pagarSena();
        uint256 retenido = SENA * 30 / 100;
        _devolver(SENA - retenido);

        _liquidarA(propietaria, retenido);

        assertEq(propietaria.balance, retenido);
        assertEq(pasarela.disponible(RESERVA), 0);
    }

    /// @notice Se puede liquidar en partes (por ejemplo, un saldo que se pagó tarde), pero nunca más de lo que entró.
    function test_SeLiquidaEnPartesSinPasarseDeLoDepositado() public {
        _pagarSena();
        _liquidarA(propietaria, SENA);

        _pagarSaldo();
        _liquidarA(propietaria, SALDO);
        assertEq(propietaria.balance, SENA + SALDO);

        address payable[] memory destinatarios = new address payable[](1);
        destinatarios[0] = propietaria;
        uint256[] memory montos = new uint256[](1);
        montos[0] = 1;
        vm.prank(plataforma);
        vm.expectRevert(abi.encodeWithSelector(PasarelaPago.FondosInsuficientes.selector, RESERVA, 0, 1));
        pasarela.liquidar(RESERVA, destinatarios, montos);
    }

    /// @notice Una reserva no puede usar el ETH de otra: liquidar se controla por reserva, no por el saldo del contrato.
    function test_NoSeLiquidaConElEthDeOtraReserva() public {
        _pagarSena();
        vm.prank(otro);
        pasarela.pagarSena{value: 1 ether}(99);

        address payable[] memory destinatarios = new address payable[](1);
        destinatarios[0] = propietaria;
        uint256[] memory montos = new uint256[](1);
        montos[0] = SENA + 1;
        vm.prank(plataforma);
        vm.expectRevert(abi.encodeWithSelector(PasarelaPago.FondosInsuficientes.selector, RESERVA, SENA, SENA + 1));
        pasarela.liquidar(RESERVA, destinatarios, montos);
    }

    /// @notice Solo la plataforma puede liquidar.
    function test_SoloLaPlataformaLiquida() public {
        _pagarSena();
        address payable[] memory destinatarios = new address payable[](1);
        destinatarios[0] = propietaria;
        uint256[] memory montos = new uint256[](1);
        montos[0] = SENA;

        vm.prank(propietaria);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, propietaria));
        pasarela.liquidar(RESERVA, destinatarios, montos);
    }

    /// @notice Listas vacías, de distinto largo, con la dirección cero o con un monto cero se rechazan.
    function test_LiquidarConDatosInvalidosSeRechaza() public {
        _pagarSena();
        address payable[] memory vacia = new address payable[](0);
        uint256[] memory sinMontos = new uint256[](0);
        address payable[] memory uno = new address payable[](1);
        uno[0] = propietaria;
        uint256[] memory dos = new uint256[](2);
        dos[0] = 1;
        dos[1] = 1;
        address payable[] memory cero = new address payable[](1);
        uint256[] memory montoUno = new uint256[](1);
        montoUno[0] = 1;
        uint256[] memory montoCero = new uint256[](1);

        vm.startPrank(plataforma);
        vm.expectRevert(PasarelaPago.ListasInvalidas.selector);
        pasarela.liquidar(RESERVA, vacia, sinMontos);
        vm.expectRevert(PasarelaPago.ListasInvalidas.selector);
        pasarela.liquidar(RESERVA, uno, dos);
        vm.expectRevert(PasarelaPago.DestinatarioInvalido.selector);
        pasarela.liquidar(RESERVA, cero, montoUno);
        vm.expectRevert(PasarelaPago.MontoInvalido.selector);
        pasarela.liquidar(RESERVA, uno, montoCero);
        vm.stopPrank();
    }

    /// @notice Si un destinatario no acepta el ETH, se deshace toda la liquidación (nadie cobra).
    function test_SiUnDestinatarioNoAceptaElEthNadieCobra() public {
        _pagarSena();
        address payable rechaza = payable(address(new RechazaEth()));
        address payable[] memory destinatarios = new address payable[](2);
        destinatarios[0] = propietaria;
        destinatarios[1] = rechaza;
        uint256[] memory montos = new uint256[](2);
        montos[0] = SENA / 2;
        montos[1] = SENA / 2;

        vm.prank(plataforma);
        vm.expectRevert(abi.encodeWithSelector(PasarelaPago.TransferenciaFallida.selector, rechaza, SENA / 2));
        pasarela.liquidar(RESERVA, destinatarios, montos);

        assertEq(propietaria.balance, 0);
        assertEq(pasarela.disponible(RESERVA), SENA);
    }

    /// @notice Un ataque de reentrada (volver a entrar a liquidar mientras se manda el ETH) se frena y no saca nada.
    function test_LaReentradaSeFrena() public {
        PlataformaReentrante atacante = new PlataformaReentrante();
        PasarelaPago objetivo = new PasarelaPago(address(atacante));
        atacante.preparar(objetivo, RESERVA);
        vm.prank(juan);
        objetivo.pagarSena{value: SENA}(RESERVA);

        // la segunda entrada choca con nonReentrant, el receive falla y toda la liquidación se deshace
        vm.expectRevert(abi.encodeWithSelector(PasarelaPago.TransferenciaFallida.selector, address(atacante), SENA / 2));
        atacante.liquidarseA(SENA / 2);

        assertEq(address(objetivo).balance, SENA);
        assertEq(objetivo.disponible(RESERVA), SENA);
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

        assertEq(_reserva(RESERVA).depositado, sena + saldo);
        assertEq(address(pasarela).balance, sena + saldo);
    }

    /// @notice Para cualquier par de reservas distintas, el pago de una no toca a la otra.
    function testFuzz_LasReservasNoSeMezclan(uint256 reservaA, uint256 reservaB) public {
        vm.assume(reservaA != reservaB);

        vm.prank(juan);
        pasarela.pagarSena{value: SENA}(reservaA);

        PasarelaPago.Reserva memory otra = _reserva(reservaB);
        assertEq(otra.huesped, address(0));
        assertEq(otra.depositado, 0);

        // la otra reserva todavía puede recibir su seña, de otra billetera
        vm.prank(otro);
        pasarela.pagarSena{value: SENA}(reservaB);
        assertEq(_reserva(reservaB).huesped, otro);
    }

    /// @notice Para cualquier combinación de pagos, devolución y liquidación: nunca sale más de lo que entró,
    ///         y el ETH del contrato es siempre lo depositado menos lo liberado.
    function testFuzz_NuncaSaleMasDeLoQueEntro(uint256 sena, uint256 saldo, uint256 devuelto, uint256 liquidado)
        public
    {
        sena = bound(sena, 1, 5 ether);
        saldo = bound(saldo, 1, 5 ether);
        vm.prank(juan);
        pasarela.pagarSena{value: sena}(RESERVA);
        vm.prank(juan);
        pasarela.pagarSaldo{value: saldo}(RESERVA);
        uint256 depositado = sena + saldo;

        // devolver: si pide más de lo que hay, se rechaza; si no, sale
        devuelto = bound(devuelto, 1, 2 * depositado);
        vm.prank(plataforma);
        if (devuelto > depositado) {
            vm.expectRevert(
                abi.encodeWithSelector(PasarelaPago.FondosInsuficientes.selector, RESERVA, depositado, devuelto)
            );
            pasarela.devolver(RESERVA, juan, devuelto);
            devuelto = 0;
        } else {
            pasarela.devolver(RESERVA, juan, devuelto);
        }

        // liquidar: lo mismo con lo que quedó
        uint256 restante = depositado - devuelto;
        liquidado = bound(liquidado, 1, 2 * depositado);
        address payable[] memory destinatarios = new address payable[](1);
        destinatarios[0] = propietaria;
        uint256[] memory montos = new uint256[](1);
        montos[0] = liquidado;
        vm.prank(plataforma);
        if (liquidado > restante) {
            vm.expectRevert(
                abi.encodeWithSelector(PasarelaPago.FondosInsuficientes.selector, RESERVA, restante, liquidado)
            );
            pasarela.liquidar(RESERVA, destinatarios, montos);
            liquidado = 0;
        } else {
            pasarela.liquidar(RESERVA, destinatarios, montos);
        }

        PasarelaPago.Reserva memory reserva = _reserva(RESERVA);
        assertLe(reserva.liberado, reserva.depositado);
        assertEq(reserva.liberado, devuelto + liquidado);
        assertEq(address(pasarela).balance, reserva.depositado - reserva.liberado);
        assertEq(propietaria.balance, liquidado);
    }

    // ---------- Ayudas ----------

    /// @notice Lee una reserva entera del contrato (el getter público la devuelve como una tupla de 5 valores).
    function _reserva(uint256 reservaId) private view returns (PasarelaPago.Reserva memory reserva) {
        (reserva.huesped, reserva.depositado, reserva.liberado, reserva.saldoPagado, reserva.devuelta) =
            pasarela.reservas(reservaId);
    }

    /// @notice Juan paga la seña de RESERVA.
    function _pagarSena() private {
        vm.prank(juan);
        pasarela.pagarSena{value: SENA}(RESERVA);
    }

    /// @notice Juan paga el saldo de RESERVA.
    function _pagarSaldo() private {
        vm.prank(juan);
        pasarela.pagarSaldo{value: SALDO}(RESERVA);
    }

    /// @notice La plataforma le devuelve a Juan el monto indicado de RESERVA.
    function _devolver(uint256 monto) private {
        vm.prank(plataforma);
        pasarela.devolver(RESERVA, juan, monto);
    }

    /// @notice La plataforma le liquida a un solo destinatario el monto indicado de RESERVA.
    function _liquidarA(address payable destinatario, uint256 monto) private {
        address payable[] memory destinatarios = new address payable[](1);
        destinatarios[0] = destinatario;
        uint256[] memory montos = new uint256[](1);
        montos[0] = monto;
        vm.prank(plataforma);
        pasarela.liquidar(RESERVA, destinatarios, montos);
    }
}
