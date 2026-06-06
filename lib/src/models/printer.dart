import 'dart:convert';

import 'package:thermal_printer_flutter/src/enums/printer_type.dart';

/// Representa uma impressora térmica e seus dados de conexão.
///
/// Instâncias são imutáveis; use [copyWith] para derivar novas instâncias.
class Printer {
  /// Nome da impressora.
  final String name;

  /// Endereço IP (impressoras de rede).
  final String ip;

  /// Porta de rede (impressoras de rede). Padrão `9100`.
  final String port;

  /// Endereço Bluetooth (impressoras BLE).
  final String bleAddress;

  /// Endereço USB (impressoras USB).
  final String usbAddress;

  /// Tipo de conexão da impressora.
  final PrinterType type;

  /// Indica se a impressora está conectada.
  final bool isConnected;

  /// Cria uma [Printer] imutável.
  const Printer({
    required this.type,
    this.name = '',
    this.ip = '',
    this.port = '9100',
    this.bleAddress = '',
    this.usbAddress = '',
    this.isConnected = false,
  });

  /// Retorna uma cópia com os campos informados substituídos.
  Printer copyWith({
    String? name,
    String? ip,
    String? port,
    String? bleAddress,
    String? usbAddress,
    PrinterType? type,
    bool? isConnected,
  }) {
    return Printer(
      name: name ?? this.name,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      bleAddress: bleAddress ?? this.bleAddress,
      usbAddress: usbAddress ?? this.usbAddress,
      type: type ?? this.type,
      isConnected: isConnected ?? this.isConnected,
    );
  }

  /// Serializa esta impressora para um `Map`.
  ///
  /// O campo `type` usa `type.name` e portanto produz `"bluetooth"`
  /// (nunca a grafia legada `"bluethoot"`).
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'ip': ip,
      'port': port,
      'bleAddress': bleAddress,
      'usbAddress': usbAddress,
      'type': type.name,
      'isConnected': isConnected,
    };
  }

  /// Cria uma [Printer] a partir de um `Map`.
  ///
  /// Mapeia defensivamente a grafia legada `"bluethoot"` para
  /// [PrinterType.bluetooth] e usa [PrinterType.usb] como fallback
  /// para valores de tipo desconhecidos.
  factory Printer.fromMap(Map<String, dynamic> map) {
    return Printer(
      name: map['name'] ?? '',
      ip: map['ip'] ?? '',
      port: map['port'] ?? '',
      bleAddress: map['bleAddress'] ?? '',
      usbAddress: map['usbAddress'] ?? '',
      type: _parsePrinterType(map['type']),
      isConnected: map['isConnected'] ?? false,
    );
  }

  /// Converte o valor serializado de `type` em [PrinterType].
  ///
  /// Aceita a grafia legada `"bluethoot"` e retorna [PrinterType.usb]
  /// quando o valor é nulo ou desconhecido.
  static PrinterType _parsePrinterType(Object? rawType) {
    if (rawType == null) return PrinterType.usb;
    final value = rawType.toString();
    if (value == 'bluethoot') return PrinterType.bluetooth;
    for (final type in PrinterType.values) {
      if (type.name == value) return type;
    }
    return PrinterType.usb;
  }

  /// Serializa esta impressora para uma `String` JSON.
  String toJson() => json.encode(toMap());

  /// Cria uma [Printer] a partir de uma `String` JSON.
  factory Printer.fromJson(String source) =>
      Printer.fromMap(json.decode(source));

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is Printer &&
        other.name == name &&
        other.ip == ip &&
        other.port == port &&
        other.bleAddress == bleAddress &&
        other.usbAddress == usbAddress &&
        other.type == type &&
        other.isConnected == isConnected;
  }

  @override
  int get hashCode {
    return name.hashCode ^
        ip.hashCode ^
        port.hashCode ^
        bleAddress.hashCode ^
        usbAddress.hashCode ^
        type.hashCode ^
        isConnected.hashCode;
  }
}
