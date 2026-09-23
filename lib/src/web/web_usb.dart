// coverage:ignore-file
// Implementação WebUSB (navigator.usb) para impressão térmica na web.
//
// Usa apenas as APIs do navegador via `dart:js_interop`. Por restrição de
// segurança do browser NÃO é possível "varrer" dispositivos silenciosamente:
//   - [usbGetDevices]   → retorna apenas os já autorizados pelo usuário
//                         (navigator.usb.getDevices), sem abrir diálogo.
//   - [usbRequestDevice]→ abre o chooser nativo para autorizar um novo
//                         dispositivo (navigator.usb.requestDevice).
//
// Suporte de navegador: Chrome/Edge/Opera (Chromium). Safari e Firefox NÃO
// implementam WebUSB. Requer contexto seguro (HTTPS ou localhost).

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'byte_chunker.dart';
import 'web_diag.dart';

// --- Bindings JS interop para a WebUSB API ------------------------------------

@JS('navigator')
external JSObject get _navigator;

@JS('navigator.usb')
external USB get _usb;

/// Indica se o navegador atual expõe a WebUSB API (`navigator.usb`).
bool webUsbAvailable() => _navigator.has('usb');

void _log(String message) => webLog('[WEB_USB] $message');

/// `navigator.usb` — ponto de entrada da WebUSB API.
extension type USB._(JSObject _) implements JSObject {
  /// Dispositivos já autorizados pelo usuário (não abre diálogo).
  external JSPromise<JSArray<USBDevice>> getDevices();

  /// Abre o chooser nativo do navegador para o usuário autorizar um device.
  external JSPromise<USBDevice> requestDevice(USBDeviceRequestOptions options);

  /// Registra um listener para os eventos `connect`/`disconnect` (é um
  /// `EventTarget`).
  external void addEventListener(String type, JSFunction listener);

  /// Remove um listener previamente registrado (mesma referência de função).
  external void removeEventListener(String type, JSFunction listener);
}

/// Opções de [USB.requestDevice]. `filters` vazio mostra todos os dispositivos.
extension type USBDeviceRequestOptions._(JSObject _) implements JSObject {
  external factory USBDeviceRequestOptions({
    required JSArray<USBDeviceFilter> filters,
  });
}

/// Filtro de [USBDeviceRequestOptions].
extension type USBDeviceFilter._(JSObject _) implements JSObject {
  external factory USBDeviceFilter({int? vendorId, int? productId, int? classCode});
}

/// Representa um dispositivo USB (`USBDevice`).
extension type USBDevice._(JSObject _) implements JSObject {
  external int get vendorId;
  external int get productId;
  external String? get productName;
  external String? get manufacturerName;
  external String? get serialNumber;
  external bool get opened;
  external USBConfiguration? get configuration;
  external JSArray<USBConfiguration> get configurations;
  external JSPromise<JSAny?> open();
  external JSPromise<JSAny?> close();
  external JSPromise<JSAny?> selectConfiguration(int configurationValue);
  external JSPromise<JSAny?> claimInterface(int interfaceNumber);
  external JSPromise<JSAny?> releaseInterface(int interfaceNumber);
  external JSPromise<USBOutTransferResult> transferOut(int endpointNumber, JSAny data);
}

/// Configuração ativa de um [USBDevice].
extension type USBConfiguration._(JSObject _) implements JSObject {
  external int get configurationValue;
  external JSArray<USBInterface> get interfaces;
}

/// Interface de uma [USBConfiguration].
extension type USBInterface._(JSObject _) implements JSObject {
  external int get interfaceNumber;
  external JSArray<USBAlternateInterface> get alternates;
}

/// Configuração alternativa de uma [USBInterface].
extension type USBAlternateInterface._(JSObject _) implements JSObject {
  external int get alternateSetting;
  external int get interfaceClass;
  external JSArray<USBEndpoint> get endpoints;
}

/// Endpoint de uma [USBAlternateInterface].
extension type USBEndpoint._(JSObject _) implements JSObject {
  external int get endpointNumber;
  external String get direction; // "in" | "out"
  external String get type; // "bulk" | "interrupt" | "isochronous"
}

/// Resultado de [USBDevice.transferOut].
extension type USBOutTransferResult._(JSObject _) implements JSObject {
  external int get bytesWritten;
  external String get status; // "ok" | "stall" | "babble"
}

// --- Helpers de alto nível ----------------------------------------------------

/// Chave estável para identificar um [USBDevice] entre chamadas.
///
/// Usa `vendorId:productId` e, quando disponível, o `serialNumber` para
/// distinguir duas unidades idênticas. Esse valor é guardado em
/// `Printer.usbAddress` para reencontrar o device JS na hora de imprimir.
String usbDeviceKey(USBDevice d) {
  final base = '${d.vendorId}:${d.productId}';
  final serial = d.serialNumber;
  return (serial != null && serial.isNotEmpty) ? '$base:$serial' : base;
}

/// Nome amigável para exibição do [USBDevice].
String usbDeviceName(USBDevice d) {
  final name = d.productName;
  if (name != null && name.isNotEmpty) return name;
  return 'USB Printer '
      '${d.vendorId.toRadixString(16)}:${d.productId.toRadixString(16)}';
}

/// Lista os dispositivos USB já autorizados (não abre diálogo).
Future<List<USBDevice>> usbGetDevices() async {
  if (!webUsbAvailable()) {
    _log('getDevices: WebUSB indisponível neste navegador');
    return [];
  }
  final devices = (await _usb.getDevices().toDart).toDart;
  _log('getDevices (origin=${webOrigin()} secure=${webIsSecureContext()}) '
      '-> ${devices.length} autorizado(s): '
      '${devices.map(usbDeviceKey).toList()}');
  return devices;
}

/// Abre o chooser nativo para o usuário autorizar uma impressora USB.
///
/// Mostra QUALQUER dispositivo no chooser — impressoras térmicas variam (classe
/// impressora 0x07, serial-USB FTDI, vendor-class), então um filtro restritivo
/// esconderia modelos válidos.
///
/// ATENÇÃO (spec WebUSB): `filters` é obrigatório e um **array vazio `[]`
/// significa NENHUM dispositivo** (nada casa). Para casar com todos, passa-se um
/// array com **um filtro vazio `[{}]`** — um filtro sem critérios casa com tudo.
/// Usar `[]` resultava em "nenhum dispositivo encontrado" no chooser.
///
/// Retorna `null` se a WebUSB não for suportada ou se o usuário cancelar.
Future<USBDevice?> usbRequestDevice() async {
  if (!webUsbAvailable()) {
    _log('requestDevice: WebUSB indisponível');
    return null;
  }
  _log('requestDevice: abrindo chooser '
      '(origin=${webOrigin()} secure=${webIsSecureContext()})');
  try {
    final options =
        USBDeviceRequestOptions(filters: <USBDeviceFilter>[USBDeviceFilter()].toJS);
    final device = await _usb.requestDevice(options).toDart;
    _log('requestDevice OK -> ${usbDeviceKey(device)}');
    return device;
  } catch (e) {
    // NotFoundError = usuário cancelou OU nenhum dispositivo no chooser.
    // SecurityError = bloqueado por Permissions-Policy / contexto inseguro.
    _log('requestDevice FALHOU: ${describeJsError(e)}');
    return null;
  }
}

/// Garante uma impressora USB seguindo o padrão recomendado pela WebUSB:
/// reutiliza um dispositivo **já autorizado** ([usbGetDevices]) e só abre o
/// chooser ([usbRequestDevice]) se nenhum estiver pareado.
///
/// Idempotente: depois de autorizado uma vez, as chamadas seguintes retornam o
/// mesmo dispositivo **sem reabrir o diálogo** — desde que a origem seja a
/// mesma. ATENÇÃO: a permissão WebUSB é por origem (esquema + host + **porta**),
/// então em dev use uma porta fixa (`flutter run -d chrome --web-port=8080`),
/// senão cada execução vira uma origem nova e a autorização se perde.
/// Registra [onChange] para ser chamado sempre que um dispositivo USB for
/// conectado ou desconectado (eventos `connect`/`disconnect` do `navigator.usb`).
///
/// É o gatilho ideal para auto-reconexão: ao plugar a impressora, o device fica
/// momentaneamente livre (antes de o SO reassumir) e já dá para reaproveitar a
/// permissão existente via [usbGetDevices], sem chooser.
/// Retorna a referência da função registrada (para depois remover via
/// [removeUsbConnectionListeners]), ou `null` se a WebUSB não estiver disponível.
JSFunction? registerUsbConnectionListeners(void Function() onChange) {
  if (!webUsbAvailable()) return null;
  final listener = ((JSObject _) {
    _log('evento USB connect/disconnect');
    onChange();
  }).toJS;
  _usb
    ..addEventListener('connect', listener)
    ..addEventListener('disconnect', listener);
  return listener;
}

/// Remove os listeners de conexão registrados por [registerUsbConnectionListeners].
void removeUsbConnectionListeners(JSFunction? listener) {
  if (listener == null || !webUsbAvailable()) return;
  _usb
    ..removeEventListener('connect', listener)
    ..removeEventListener('disconnect', listener);
}

Future<USBDevice?> usbEnsureDevice() async {
  if (!webUsbAvailable()) return null;
  final paired = await usbGetDevices();
  if (paired.isNotEmpty) {
    _log('ensure: reusando dispositivo já autorizado '
        '${usbDeviceKey(paired.first)} (sem chooser)');
    return paired.first;
  }
  _log('ensure: nenhum dispositivo pareado nesta origem -> abrindo chooser');
  return usbRequestDevice();
}

/// Abre a conexão com o [device]. Retorna `false` em caso de falha.
Future<bool> usbOpen(USBDevice device) async {
  try {
    if (!device.opened) await device.open().toDart;
    return true;
  } catch (_) {
    return false;
  }
}

/// Fecha a conexão com o [device] (ignora erros).
Future<void> usbClose(USBDevice device) async {
  try {
    if (device.opened) await device.close().toDart;
  } catch (_) {
    // Fechamento best-effort; nada a fazer se já estiver fechado.
  }
}

/// Envia [bytes] (ESC/POS) para o [device] via endpoint BULK OUT.
///
/// Abre o dispositivo se necessário, seleciona a configuração 1 caso ainda não
/// haja uma ativa, reivindica a interface que contém o endpoint BULK OUT,
/// transfere em blocos e libera a interface ao final.
Future<void> usbPrint(USBDevice device, List<int> bytes) async {
  _log('print: início ${usbDeviceKey(device)} '
      '(opened=${device.opened}, ${bytes.length} bytes)');
  try {
    if (!device.opened) {
      await device.open().toDart;
      _log('print: open OK');
    }
    if (device.configuration == null) {
      // configurationValue é definido pelo dispositivo; usa o da primeira
      // configuração (fallback 1). claimInterface exige configuração ativa.
      final configs = device.configurations.toDart;
      final value = configs.isNotEmpty ? configs.first.configurationValue : 1;
      await device.selectConfiguration(value).toDart;
      _log('print: selectConfiguration($value) OK');
    }

    final (interfaceNumber, endpointNumber) = _findBulkOut(device);
    _log('print: BULK OUT iface=$interfaceNumber ep=$endpointNumber');
    await device.claimInterface(interfaceNumber).toDart;
    _log('print: claimInterface OK');

    try {
      // Transferência em blocos para não exceder limites do driver/USB.
      const chunkSize = 16 * 1024;
      for (final chunk in chunkBytes(bytes, chunkSize)) {
        final result =
            await device.transferOut(endpointNumber, chunk.toJS).toDart;
        // Só tratamos como erro os estados de falha explícitos do USB;
        // qualquer outro valor (incl. "ok") é sucesso, para não quebrar
        // impressões válidas por um status inesperado.
        final status = result.status;
        if (status == 'stall' || status == 'babble') {
          throw StateError('Falha na transferência USB (status: $status).');
        }
      }
      _log('print: transferência concluída OK');
    } finally {
      try {
        await device.releaseInterface(interfaceNumber).toDart;
      } catch (_) {
        // Liberação best-effort.
      }
    }
  } catch (e) {
    _log('print FALHOU: ${describeJsError(e)}');
    rethrow;
  }
}

/// Localiza o primeiro endpoint BULK OUT do [device] e retorna
/// `(interfaceNumber, endpointNumber)`.
(int, int) _findBulkOut(USBDevice device) {
  final config = device.configuration;
  if (config == null) {
    throw StateError('Dispositivo USB sem configuração ativa.');
  }
  // Em dispositivos compostos (impressora + interface vendor/serial), prefere o
  // BULK OUT da interface de classe impressora (0x07); só cai no primeiro BULK
  // OUT qualquer se não houver interface de impressora.
  (int, int)? fallback;
  for (final iface in config.interfaces.toDart) {
    for (final alt in iface.alternates.toDart) {
      for (final ep in alt.endpoints.toDart) {
        if (ep.direction == 'out' && ep.type == 'bulk') {
          if (alt.interfaceClass == 0x07) {
            return (iface.interfaceNumber, ep.endpointNumber);
          }
          fallback ??= (iface.interfaceNumber, ep.endpointNumber);
        }
      }
    }
  }
  if (fallback != null) return fallback;
  throw StateError('Nenhum endpoint BULK OUT encontrado no dispositivo USB.');
}
