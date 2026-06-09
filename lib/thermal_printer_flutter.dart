import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:thermal_printer_flutter/src/enums/printer_type.dart';
import 'package:thermal_printer_flutter/src/models/printer.dart';
import 'package:thermal_printer_flutter/src/models/printer_status.dart';
import 'package:thermal_printer_flutter/src/services/screenshot.dart';
import 'package:thermal_printer_flutter/src/repositories/network_printer_repository.dart';
import 'thermal_printer_flutter_platform_interface.dart';
export './src/models/printer.dart';
export './src/models/printer_status.dart';
export './src/enums/printer_type.dart';
export './src/services/screenshot.dart';
import 'package:image/image.dart' as img;
export 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

/// API pública do plugin de impressão térmica.
class ThermalPrinterFlutter implements ThermalPrinterFlutterPlatform {
  /// Cria a fachada do plugin.
  ///
  /// [networkRepository] é um seam de testabilidade (opcional); em produção
  /// usa a implementação real de descoberta/impressão de rede.
  ThermalPrinterFlutter({NetworkPrinterRepository? networkRepository}) : _networkRepository = networkRepository ?? NetworkPrinterRepository();

  final NetworkPrinterRepository _networkRepository;

  /// Fila serial de impressão.
  ///
  /// Garante que apenas um job de impressão esteja em andamento por vez:
  /// cada chamada de [printBytes] encadeia-se na anterior. Isso evita jobs
  /// RAW concorrentes no spooler (causa de impressão "maluca"/duplicada
  /// quando o chamador dispara [printBytes] em loop).
  Future<void> _printQueue = Future<void>.value();

  /// Drenagem entre jobs Bluetooth (BLE).
  ///
  /// A impressora confirma o RECEBIMENTO dos bytes (no buffer dela) muito antes
  /// de terminar de IMPRIMIR. O buffer aguenta UM job grande (texto OU imagem),
  /// mas se o próximo job entra logo em seguida (ex.: imagem após um texto
  /// longo) os dois coexistem no buffer e ele estoura → a impressão trunca ou a
  /// impressora congela. Por isso seguramos o fim de cada job BLE por um tempo
  /// proporcional ao volume enviado, dando à impressora tempo de drenar antes do
  /// próximo. Só afeta Bluetooth (USB/rede vão por spooler/socket).
  ///
  /// Calibragem por hardware: se ainda bugar na transição, DIMINUA
  /// [_bleDrainBytesPerMs] (mais pausa); se a pausa entre jobs incomodar e não
  /// bugar, AUMENTE. `0` desliga a drenagem.
  static const double _bleDrainBytesPerMs = 4.0;
  static const int _bleDrainMaxMs = 5000;

  /// Executa [action] de forma serializada em relação a outras impressões.
  ///
  /// Erros de uma impressão não interrompem a fila das próximas.
  Future<T> _enqueuePrint<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _printQueue;
    // A fila avança independentemente de [action] ter sucesso ou falha.
    _printQueue = completer.future.then<void>(
      (_) {},
      onError: (_) {},
    );
    previous.whenComplete(() async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  /// Retorna a versão da plataforma host.
  @override
  Future<String?> getPlatformVersion() async {
    return await ThermalPrinterFlutterPlatform.instance.getPlatformVersion();
  }

  /// Verifica se as permissões de Bluetooth foram concedidas.
  @override
  Future<bool> checkBluetoothPermissions() async {
    return await ThermalPrinterFlutterPlatform.instance.checkBluetoothPermissions();
  }

  /// Indica se o Bluetooth está habilitado no dispositivo.
  @override
  Future<bool> isBluetoothEnabled() async {
    return await ThermalPrinterFlutterPlatform.instance.isBluetoothEnabled();
  }

  /// Solicita a habilitação do Bluetooth no dispositivo.
  @override
  Future<bool> enableBluetooth() async {
    return await ThermalPrinterFlutterPlatform.instance.enableBluetooth();
  }

  /// Lista as impressoras disponíveis para o [printerType] informado.
  @override
  Future<List<Printer>> getPrinters({required PrinterType printerType}) async {
    return await ThermalPrinterFlutterPlatform.instance.getPrinters(printerType: printerType);
  }

  /// Abre o seletor de dispositivos para o usuário autorizar uma impressora.
  ///
  /// Voltado para a **Web/USB** (WebUSB): abre o chooser nativo do navegador e
  /// retorna a impressora autorizada. Em plataformas nativas retorna `null`
  /// (use [getPrinters]). Também retorna `null` se o navegador não suportar
  /// WebUSB, ou se o usuário cancelar/não selecionar nada.
  ///
  /// Na web, [getPrinters] lista apenas dispositivos já autorizados; chame
  /// este método (a partir de um gesto do usuário, ex.: clique de botão) para
  /// autorizar um novo.
  @override
  Future<Printer?> requestPrinter({required PrinterType printerType}) async {
    return await ThermalPrinterFlutterPlatform.instance.requestPrinter(printerType: printerType);
  }

  /// Indica se o navegador suporta impressão USB via WebUSB.
  ///
  /// Retorna `true` apenas na Web em navegadores Chromium com `navigator.usb`.
  /// Use para decidir se vale abrir o chooser com [requestPrinter] ou orientar
  /// o usuário a trocar de navegador.
  @override
  Future<bool> isWebUsbSupported() async {
    return await ThermalPrinterFlutterPlatform.instance.isWebUsbSupported();
  }

  /// Indica se o navegador suporta impressão Bluetooth BLE via Web Bluetooth.
  ///
  /// Retorna `true` apenas na Web em navegadores Chromium com
  /// `navigator.bluetooth`. Use para decidir se vale abrir o chooser com
  /// [requestPrinter] (Bluetooth) ou orientar o usuário.
  @override
  Future<bool> isWebBluetoothSupported() async {
    return await ThermalPrinterFlutterPlatform.instance.isWebBluetoothSupported();
  }

  /// Emite quando um dispositivo USB conecta/desconecta (apenas Web).
  ///
  /// Assine para **auto-reconectar** impressoras já autorizadas ao plugar o
  /// cabo: no evento, chame [getPrinters]/[requestPrinter] novamente (que
  /// reaproveitam a permissão existente sem abrir o chooser). Útil no macOS,
  /// onde o replug é o momento em que o dispositivo fica livre. Fora da Web é um
  /// stream vazio.
  @override
  Stream<void> get onWebUsbConnectionChange => ThermalPrinterFlutterPlatform.instance.onWebUsbConnectionChange;

  /// Descobre automaticamente impressoras de rede na rede local
  ///
  /// Escaneia a rede local procurando por impressoras nas portas comuns:
  /// - 9100 (Raw TCP/IP - mais comum para impressoras térmicas)
  /// - 515 (LPR/LPD)
  /// - 631 (IPP - Internet Printing Protocol)
  ///
  /// [onProgress] - Callback opcional para receber atualizações do progresso
  ///
  /// [requireConfirmation] - Quando `true`, retorna apenas impressoras
  /// confirmadas via sonda ESC/POS (porta 9100), reduzindo falsos positivos
  /// (ex.: hosts com CUPS na 631 ou outros serviços na 9100).
  ///
  /// Retorna uma lista de impressoras encontradas na rede
  Future<List<Printer>> discoverNetworkPrinters({
    Function(String)? onProgress,
    bool requireConfirmation = false,
  }) async {
    return await _networkRepository.discoverNetworkPrinters(onProgress: onProgress, requireConfirmation: requireConfirmation);
  }

  /// Envia [bytes] (ESC/POS) para a [printer].
  ///
  /// [copies] controla quantas vias serão impressas (padrão `1`). As cópias
  /// são montadas no próprio fluxo de bytes (o payload é repetido [copies]
  /// vezes) e enviadas em **um único job**, de forma idêntica em todas as
  /// plataformas. Não dependa do contador de cópias do driver — no Windows
  /// ele é forçado para `1` justamente para que a quantidade aqui seja a
  /// fonte da verdade.
  ///
  /// Prefira passar [copies] em vez de chamar [printBytes] em laço: as
  /// chamadas são serializadas internamente, mas uma única chamada com
  /// [copies] gera um job só e é mais previsível.
  ///
  /// Cada via repete exatamente [bytes]; portanto garanta que o payload
  /// termine com o corte/avanço desejado (ex.: `generator.cut()`).
  @override
  Future<void> printBytes({
    required List<int> bytes,
    required Printer printer,
    int copies = 1,
  }) {
    assert(copies >= 1, 'copies deve ser >= 1');
    if (copies < 1) copies = 1;

    final List<int> payload = copies == 1 ? bytes : <int>[for (int i = 0; i < copies; i++) ...bytes];

    return _enqueuePrint(() async {
      await ThermalPrinterFlutterPlatform.instance.printBytes(bytes: payload, printer: printer);

      // Drenagem entre jobs BLE: segura a fila serial até a impressora ter tempo
      // de imprimir este job, pra o próximo não empilhar dados num buffer cheio.
      if (printer.type == PrinterType.bluetooth && _bleDrainBytesPerMs > 0) {
        final drainMs = (payload.length / _bleDrainBytesPerMs).round().clamp(0, _bleDrainMaxMs);
        if (drainMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: drainMs));
        }
      }
    });
  }

  /// Conecta-se à [printer].
  @override
  Future<bool> connect({required Printer printer}) async {
    return await ThermalPrinterFlutterPlatform.instance.connect(printer: printer);
  }

  /// Desconecta-se da [printer].
  @override
  Future<void> disconnect({required Printer printer}) async {
    await ThermalPrinterFlutterPlatform.instance.disconnect(printer: printer);
  }

  /// Indica se a [printer] está conectada.
  @override
  Future<bool> isConnected({required Printer printer}) async {
    return await ThermalPrinterFlutterPlatform.instance.isConnected(printer: printer);
  }

  @override
  Future<PrinterStatus> getPrinterStatus({required Printer printer}) async {
    return await ThermalPrinterFlutterPlatform.instance.getPrinterStatus(printer: printer);
  }

  /// Libera recursos retidos pelo plugin (conexões de rede em pool).
  ///
  /// Chame ao descartar o plugin para não vazar sockets abertos.
  @override
  Future<void> dispose() async {
    await ThermalPrinterFlutterPlatform.instance.dispose();
    await _networkRepository.dispose();
  }

  /// Renderiza [widget] e retorna a imagem monocromática pronta para impressão.
  Future<img.Image> screenShotWidget(
    BuildContext context, {
    required Widget widget,
    double pixelRatio = 3.0,
    int width = 576, // 80 mm @ 203 dpi (múltiplo de 8). Use 384 p/ 58 mm.
    int threshold = 160,
    bool flipHorizontal = false,
    bool applyTextScaling = true,
    bool useBetterText = true,
    double textScaleFactor = 1.3,
    bool dither = true,
  }) async {
    return await ThermalScreenshot.captureWidgetAsMonochromeImage(context,
        widget: widget,
        flipHorizontal: flipHorizontal,
        pixelRatio: pixelRatio,
        threshold: threshold,
        width: width,
        applyTextScaling: applyTextScaling,
        useBetterText: useBetterText,
        textScaleFactor: textScaleFactor,
        dither: dither);
  }
}
