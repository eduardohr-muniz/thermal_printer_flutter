import 'dart:developer';
import 'package:flutter/services.dart';
import 'package:thermal_printer_flutter/thermal_printer_flutter.dart';
import 'printer_repository.dart';

class BluetoothPrinterRepository implements PrinterRepository {
  /// Cria o repositório Bluetooth.
  ///
  /// [reconnectDelay] é a pausa após desconectar antes de reconectar em
  /// [connect] (alguns adaptadores precisam de um respiro). Exposto para
  /// permitir testes rápidos e ajuste fino.
  BluetoothPrinterRepository({
    Duration reconnectDelay = const Duration(milliseconds: 500),
  }) : _reconnectDelay = reconnectDelay;

  final Duration _reconnectDelay;
  final MethodChannel _channel = const MethodChannel('thermal_printer_flutter');

  @override
  Future<List<Printer>> getPrinters() async {
    try {
      final List<dynamic> devices =
          await _channel.invokeMethod<List<dynamic>>('pairedbluetooths') ?? [];
      return devices.map((device) {
        if (device is Map) {
          return Printer(
            type: PrinterType.bluetooth,
            name: device['name'] ?? '',
            bleAddress: device['bleAddress'] ?? '',
            isConnected: device['isConnected'] ?? false,
          );
        } else if (device is String) {
          // Formato esperado: "name#address". Trata defensivamente entradas
          // sem '#' para não descartar a lista inteira por um item malformado.
          final parts = device.split('#');
          return Printer(
            type: PrinterType.bluetooth,
            name: parts.isNotEmpty ? parts[0] : '',
            bleAddress: parts.length > 1 ? parts[1] : '',
          );
        }
        return Printer(
          type: PrinterType.bluetooth,
        );
      }).toList();
    } catch (e) {
      log('Erro ao obter impressoras Bluetooth: $e',
          name: 'THERMAL_PRINTER_FLUTTER');
      return [];
    }
  }

  @override
  Future<bool> connect(Printer printer) async {
    try {
      // Primeiro desconecta qualquer conexão existente
      await disconnect(printer);

      // Aguarda um momento para garantir que a desconexão foi concluída
      await Future.delayed(_reconnectDelay);

      // Tenta conectar
      final bool result =
          await _channel.invokeMethod<bool>('connect', printer.bleAddress) ??
              false;
      return result;
    } catch (e) {
      log('Erro ao conectar impressora Bluetooth: $e',
          name: 'THERMAL_PRINTER_FLUTTER');
      return false;
    }
  }

  @override
  Future<void> disconnect(Printer printer) async {
    try {
      await _channel.invokeMethod('disconnect');
    } catch (e) {
      log('Erro ao desconectar impressora Bluetooth: $e',
          name: 'THERMAL_PRINTER_FLUTTER');
    }
  }

  @override
  Future<void> printBytes(
      {required List<int> bytes, required Printer printer}) async {
    try {
      await _channel.invokeMethod('writebytes', Uint8List.fromList(bytes));
    } catch (e) {
      log('Erro ao imprimir bytes: $e', name: 'THERMAL_PRINTER_FLUTTER');
      rethrow;
    }
  }

  @override
  Future<bool> isConnected(Printer printer) async {
    try {
      final bool result = await _channel.invokeMethod<bool>(
              'isConnected', printer.bleAddress) ??
          false;
      return result;
    } catch (e) {
      log('Erro ao verificar conexão Bluetooth: $e',
          name: 'THERMAL_PRINTER_FLUTTER');
      return false;
    }
  }
}
