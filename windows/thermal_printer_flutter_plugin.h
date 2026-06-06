#ifndef FLUTTER_PLUGIN_THERMAL_PRINTER_FLUTTER_PLUGIN_H_
#define FLUTTER_PLUGIN_THERMAL_PRINTER_FLUTTER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/encodable_value.h>

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
};

}  // namespace thermal_printer_flutter

#endif  // FLUTTER_PLUGIN_THERMAL_PRINTER_FLUTTER_PLUGIN_H_
