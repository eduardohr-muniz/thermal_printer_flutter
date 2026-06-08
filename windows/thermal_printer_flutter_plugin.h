#ifndef FLUTTER_PLUGIN_THERMAL_PRINTER_FLUTTER_PLUGIN_H_
#define FLUTTER_PLUGIN_THERMAL_PRINTER_FLUTTER_PLUGIN_H_

// winsock2.h MUST be included before any header that pulls in <windows.h>
// (the Flutter headers below do). It also defines _WINSOCKAPI_, which stops
// windows.h from including the legacy winsock.h and causing redefinitions.
#include <winsock2.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/encodable_value.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace thermal_printer_flutter {

class ThermalPrinterFlutterPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  ThermalPrinterFlutterPlugin();
  virtual ~ThermalPrinterFlutterPlugin();

  // Disallow copy and assign.
  ThermalPrinterFlutterPlugin(const ThermalPrinterFlutterPlugin&) = delete;
  ThermalPrinterFlutterPlugin& operator=(const ThermalPrinterFlutterPlugin&) = delete;

  /// Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  /// Enumerate local and network-connected printers.
  std::vector<std::string> GetPrinters();

  /// Send raw bytes to the named Windows print spooler.
  /// Returns true on full success, false on any Win32 failure.
  bool PrintBytes(const std::vector<uint8_t>& bytes,
                  const std::string& printerName);

  /// Convert a UTF-8 std::string to a wide std::wstring (safe, no raw new[]).
  static std::wstring StringToWideString(const std::string& utf8);

  /// Extract a byte payload from an EncodableValue.
  /// Accepts FlutterStandardTypedData (vector<uint8_t>) first,
  /// then falls back to EncodableList of int32_t for legacy callers.
  static std::optional<std::vector<uint8_t>>
      ExtractBytes(const flutter::EncodableValue& value);

  /// Build a status map for the named printer (online, paper, errors).
  flutter::EncodableMap BuildPrinterStatusMap(const std::string& printerName);

  /// Populate a status map with default/unknown values.
  void PopulateDefaultStatus(flutter::EncodableMap& statusMap) const;

  // ── Bluetooth (RFCOMM / SPP over Winsock) ────────────────────────────────
  //
  // Mirrors the Android path: connect to a paired SPP printer by address,
  // stream raw ESC/POS bytes over an RFCOMM socket, one connection at a time.

  /// Lazily initialize Winsock (WSAStartup). Returns true once ready.
  bool EnsureWinsock();

  /// Enumerate paired/remembered Bluetooth devices as maps
  /// {name, bleAddress, type:"bluetooth", isConnected:false}.
  flutter::EncodableList GetPairedBluetoothDevices();

  /// Open an RFCOMM connection to the SPP service of [address] (a
  /// "XX:XX:XX:XX:XX:XX" string). Closes any previous connection first.
  bool BluetoothConnect(const std::string& address);

  /// Send the whole payload to the active connection (single stream, no
  /// chunking — matches the Android behaviour).
  bool BluetoothWrite(const std::vector<uint8_t>& bytes);

  /// Close the active connection, if any.
  void BluetoothDisconnect();

  /// Whether an RFCOMM connection is currently open.
  bool BluetoothIsConnected() const;

  /// Whether the machine has at least one Bluetooth radio.
  bool IsBluetoothRadioPresent() const;

  /// Parse "XX:XX:XX:XX:XX:XX" (colons optional) into a 48-bit BTH_ADDR.
  static std::optional<unsigned long long>
      ParseBluetoothAddress(const std::string& mac);

  /// Format a 48-bit BTH_ADDR as an upper-case "XX:XX:XX:XX:XX:XX" string.
  static std::string FormatBluetoothAddress(unsigned long long addr);

  /// Last Winsock/connect error (diagnostics). -1 means "bad address string".
  int last_bt_error_ = 0;

  /// Active RFCOMM socket (INVALID_SOCKET when disconnected).
  SOCKET bt_socket_ = INVALID_SOCKET;

  /// Whether WSAStartup succeeded (so we WSACleanup in the destructor).
  bool wsa_started_ = false;
};

}  // namespace thermal_printer_flutter

#endif  // FLUTTER_PLUGIN_THERMAL_PRINTER_FLUTTER_PLUGIN_H_
