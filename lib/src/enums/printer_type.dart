/// Tipos de impressora suportados pelo plugin.
enum PrinterType {
  /// Impressora conectada via USB (CUPS/spooler).
  usb,

  /// Impressora conectada via Bluetooth (BLE).
  bluetooth,

  /// Impressora conectada via rede (TCP/IP).
  network;
}

/// Alias depreciado de [PrinterType.bluetooth] (grafia legada).
///
/// Permite que código existente que usava o valor com grafia errada
/// continue compilando. Prefira [PrinterType.bluetooth].
@Deprecated('Use PrinterType.bluetooth')
PrinterType get bluethoot => PrinterType.bluetooth;

/// Shim de depreciação para o valor de enum legado `bluethoot`.
///
/// Disponível também como [PrinterTypeLegacy.bluethoot]. Prefira
/// [PrinterType.bluetooth].
extension PrinterTypeLegacy on PrinterType {
  /// Alias depreciado de [PrinterType.bluetooth] (grafia legada).
  @Deprecated('Use PrinterType.bluetooth')
  static PrinterType get bluethoot => PrinterType.bluetooth;
}
