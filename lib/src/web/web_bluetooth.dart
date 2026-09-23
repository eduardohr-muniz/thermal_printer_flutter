// coverage:ignore-file
// Implementação Web Bluetooth (navigator.bluetooth / BLE) para impressão
// térmica na web. Usa apenas APIs do navegador via `dart:js_interop`.
//
// Modelo de descoberta (igual ao WebUSB, por restrição de segurança do
// browser):
//   - [bleGetDevices]    → dispositivos já autorizados (experimental; pode não
//                          existir em todos os navegadores), sem abrir diálogo.
//   - [bleRequestDevice] → abre o chooser nativo (navigator.bluetooth
//                          .requestDevice) para autorizar um novo dispositivo.
//
// Suporte de navegador: Chrome/Edge/Opera (Chromium). Safari e Firefox NÃO
// implementam Web Bluetooth. Requer contexto seguro (HTTPS ou localhost) e
// somente **BLE** — Bluetooth clássico (RFCOMM) não é suportado no browser.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'byte_chunker.dart';
import 'web_diag.dart';

/// Serviços GATT conhecidos de impressoras térmicas BLE.
///
/// O Web Bluetooth só expõe serviços previamente declarados em
/// `optionalServices`; por isso listamos os UUIDs mais comuns de impressoras
/// ESC/POS BLE. Se a sua impressora usar um serviço fora desta lista, ele não
/// ficará acessível e será preciso adicioná-lo aqui.
const List<String> printerServiceUuids = <String>[
  '000018f0-0000-1000-8000-00805f9b34fb', // ESC/POS comum (char write 00002af1)
  '0000ff00-0000-1000-8000-00805f9b34fb', // comum (char write 0000ff02)
  '0000ffe0-0000-1000-8000-00805f9b34fb', // módulos seriais BLE (HM-10, char ffe1)
  '0000fee7-0000-1000-8000-00805f9b34fb', // diversos fabricantes
  '6e400001-b5a3-f393-e0a9-e50e24dcca9e', // Nordic UART (char write 6e400002)
  '49535343-fe7d-4ae5-8fa9-9fafd205e455', // Microchip/ISSC transparent UART
];

// --- Bindings JS interop para a Web Bluetooth API -----------------------------

@JS('navigator')
external JSObject get _navigator;

@JS('navigator.bluetooth')
external Bluetooth get _bluetooth;

/// Indica se o navegador atual expõe a Web Bluetooth API (`navigator.bluetooth`).
bool webBluetoothAvailable() => _navigator.has('bluetooth');

void _log(String message) => webLog('[WEB_BLE] $message');

/// `navigator.bluetooth` — ponto de entrada da Web Bluetooth API.
extension type Bluetooth._(JSObject _) implements JSObject {
  external JSPromise<BluetoothDevice> requestDevice(RequestDeviceOptions options);

  /// Dispositivos já autorizados (experimental; pode não existir).
  external JSPromise<JSArray<BluetoothDevice>> getDevices();
}

/// Opções de [Bluetooth.requestDevice].
extension type RequestDeviceOptions._(JSObject _) implements JSObject {
  external factory RequestDeviceOptions({
    bool? acceptAllDevices,
    JSArray<JSString>? optionalServices,
  });
}

/// Representa um dispositivo BLE (`BluetoothDevice`).
extension type BluetoothDevice._(JSObject _) implements JSObject {
  external String get id;
  external String? get name;
  external BluetoothRemoteGATTServer? get gatt;

  /// `BluetoothDevice` é um `EventTarget` (emite `gattserverdisconnected`).
  external void addEventListener(String type, JSFunction listener);
}

/// Servidor GATT de um [BluetoothDevice].
extension type BluetoothRemoteGATTServer._(JSObject _) implements JSObject {
  external bool get connected;
  external JSPromise<BluetoothRemoteGATTServer> connect();
  external void disconnect();
  external JSPromise<JSArray<BluetoothRemoteGATTService>> getPrimaryServices();
}

/// Serviço GATT primário.
extension type BluetoothRemoteGATTService._(JSObject _) implements JSObject {
  external String get uuid;
  external JSPromise<JSArray<BluetoothRemoteGATTCharacteristic>>
      getCharacteristics();
}

/// Característica GATT.
extension type BluetoothRemoteGATTCharacteristic._(JSObject _)
    implements JSObject {
  external String get uuid;
  external BluetoothCharacteristicProperties get properties;
  external JSPromise<JSAny?> writeValueWithResponse(JSAny value);
  external JSPromise<JSAny?> writeValueWithoutResponse(JSAny value);
}

/// Propriedades de uma [BluetoothRemoteGATTCharacteristic].
extension type BluetoothCharacteristicProperties._(JSObject _)
    implements JSObject {
  external bool get write;
  external bool get writeWithoutResponse;
}

// --- Helpers de alto nível ----------------------------------------------------

/// Chave estável do dispositivo BLE (id opaco por origem). Guardada em
/// `Printer.bleAddress` para reencontrar o objeto JS ao imprimir/conectar.
String bleDeviceKey(BluetoothDevice d) => d.id;

/// Nome amigável para exibição do dispositivo BLE.
String bleDeviceName(BluetoothDevice d) {
  final name = d.name;
  return (name != null && name.isNotEmpty) ? name : 'BLE Printer ${d.id}';
}

/// Abre o chooser nativo para o usuário autorizar uma impressora BLE.
///
/// Usa `acceptAllDevices` para que QUALQUER dispositivo BLE apareça (impressoras
/// variam de serviço), declarando [printerServiceUuids] em `optionalServices`
/// para poder acessá-los depois. Retorna `null` se a Web Bluetooth não for
/// suportada ou se o usuário cancelar.
Future<BluetoothDevice?> bleRequestDevice() async {
  if (!webBluetoothAvailable()) return null;
  _log('requestDevice: abrindo chooser '
      '(origin=${webOrigin()} secure=${webIsSecureContext()})');
  try {
    final options = RequestDeviceOptions(
      acceptAllDevices: true,
      optionalServices: printerServiceUuids.map((s) => s.toJS).toList().toJS,
    );
    final device = await _bluetooth.requestDevice(options).toDart;
    _log('requestDevice OK -> ${bleDeviceName(device)} (${device.id})');
    return device;
  } catch (e) {
    _log('requestDevice FALHOU: ${describeJsError(e)}');
    return null;
  }
}

/// Lista dispositivos BLE já autorizados (experimental; vazio se indisponível).
Future<List<BluetoothDevice>> bleGetDevices() async {
  if (!webBluetoothAvailable()) return [];
  if (!_bluetooth.has('getDevices')) return [];
  try {
    final devices = await _bluetooth.getDevices().toDart;
    return devices.toDart;
  } catch (_) {
    return [];
  }
}

/// Garante uma impressora BLE: reutiliza um dispositivo já autorizado
/// ([bleGetDevices]) e só abre o chooser ([bleRequestDevice]) se nenhum estiver
/// pareado. Observação: `getDevices` da Web Bluetooth é experimental e pode não
/// existir; nesse caso sempre cai no chooser.
Future<BluetoothDevice?> bleEnsureDevice() async {
  if (!webBluetoothAvailable()) return null;
  final paired = await bleGetDevices();
  if (paired.isNotEmpty) return paired.first;
  return bleRequestDevice();
}

/// Conecta ao servidor GATT do [device]. Retorna `false` em caso de falha.
Future<bool> bleConnect(BluetoothDevice device) async {
  try {
    final gatt = device.gatt;
    if (gatt == null) return false;
    if (!gatt.connected) await gatt.connect().toDart;
    return gatt.connected;
  } catch (_) {
    return false;
  }
}

/// Cache da característica de escrita por dispositivo (chave = [bleDeviceKey]).
///
/// Evita refazer a descoberta de serviços/características (várias idas e voltas
/// GATT, a parte mais lenta) a cada impressão. Invalidado ao desconectar e ao
/// reconectar (o objeto da característica fica obsoleto após reconexão).
final Map<String, BluetoothRemoteGATTCharacteristic> _writeCharCache = {};

/// Dispositivos para os quais já registramos o listener de desconexão (evita
/// registrar mais de uma vez por dispositivo).
final Set<String> _disconnectWatched = <String>{};

/// Desconecta do servidor GATT do [device] (ignora erros).
void bleDisconnect(BluetoothDevice device) {
  _writeCharCache.remove(bleDeviceKey(device));
  final gatt = device.gatt;
  if (gatt != null && gatt.connected) gatt.disconnect();
}

/// Indica se há conexão GATT ativa com o [device].
bool bleConnected(BluetoothDevice device) => device.gatt?.connected ?? false;

/// Envia [bytes] (ESC/POS) para o [device] via a primeira característica de
/// escrita encontrada num serviço conhecido.
///
/// Conecta o GATT se necessário, localiza a característica de escrita, e
/// transfere em blocos (BLE limita o tamanho por escrita). Usa
/// `writeValueWithResponse` quando disponível (mais confiável p/ payloads
/// grandes via long-write), caso contrário `writeValueWithoutResponse`.
Future<void> blePrint(BluetoothDevice device, List<int> bytes) async {
  _log('print: início ${bleDeviceName(device)} (${bytes.length} bytes)');
  try {
    final ch = await _findWriteCharacteristic(device);
    final withResponse = ch.properties.write;
    // Sem resposta é limitado pelo MTU; usamos um bloco conservador.
    final chunkSize = withResponse ? 512 : 180;
    _log('print: característica ${ch.uuid} '
        '(withResponse=$withResponse, chunk=$chunkSize)');

    for (final chunk in chunkBytes(bytes, chunkSize)) {
      if (withResponse) {
        // A resposta de cada escrita já serve de controle de fluxo.
        await ch.writeValueWithResponse(chunk.toJS).toDart;
      } else {
        // Sem resposta não há controle de fluxo GATT; um pequeno intervalo
        // entre blocos evita estourar o buffer pequeno da impressora.
        await ch.writeValueWithoutResponse(chunk.toJS).toDart;
        await Future<void>.delayed(const Duration(milliseconds: 6));
      }
    }
    _log('print: transferência concluída OK');
  } catch (e) {
    _log('print FALHOU: ${describeJsError(e)}');
    rethrow;
  }
}

/// Conecta (se preciso) e retorna a primeira característica de escrita de um
/// serviço conhecido do [device].
Future<BluetoothRemoteGATTCharacteristic> _findWriteCharacteristic(
    BluetoothDevice device) async {
  final gatt = device.gatt;
  if (gatt == null) {
    throw StateError('Dispositivo BLE sem servidor GATT.');
  }
  final key = bleDeviceKey(device);

  // Invalida o cache assim que a conexão cair (inclusive quedas não
  // solicitadas / auto-reconexão), evitando reusar uma característica obsoleta.
  if (!_disconnectWatched.contains(key)) {
    _disconnectWatched.add(key);
    device.addEventListener(
      'gattserverdisconnected',
      ((JSObject _) {
        _writeCharCache.remove(key);
        _log('GATT desconectado -> cache da característica invalidado');
      }).toJS,
    );
  }

  if (!gatt.connected) {
    await gatt.connect().toDart;
    _log('GATT conectado');
    // Característica anterior fica obsoleta após reconectar.
    _writeCharCache.remove(key);
  }

  final cached = _writeCharCache[key];
  if (cached != null) {
    _log('característica reaproveitada do cache (${cached.uuid})');
    return cached;
  }

  // getPrimaryServices só retorna serviços declarados em optionalServices.
  final services = (await gatt.getPrimaryServices().toDart).toDart;
  _log('serviços conhecidos encontrados: '
      '${services.map((s) => s.uuid).toList()}');
  for (final service in services) {
    final characteristics = (await service.getCharacteristics().toDart).toDart;
    for (final ch in characteristics) {
      final props = ch.properties;
      if (props.write || props.writeWithoutResponse) {
        _writeCharCache[key] = ch;
        return ch;
      }
    }
  }
  throw StateError(
      'Nenhuma característica BLE de escrita encontrada. A impressora pode usar '
      'um serviço GATT fora da lista conhecida (printerServiceUuids).');
}
