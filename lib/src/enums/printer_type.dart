/// Tipos de impressora suportados pelo plugin.
enum PrinterType {
  /// Impressora conectada via USB (CUPS/spooler).
  usb,

  /// Impressora conectada via Bluetooth (BLE).
  bluetooth,

  /// Impressora conectada via rede (TCP/IP).
  network;
}
