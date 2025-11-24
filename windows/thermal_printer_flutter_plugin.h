#ifndef FLUTTER_PLUGIN_THERMAL_PRINTER_FLUTTER_PLUGIN_H_
#define FLUTTER_PLUGIN_THERMAL_PRINTER_FLUTTER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/encodable_value.h>

#include <memory>
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

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  std::vector<std::string> GetPrinters();
  void PrintBytes(const std::vector<uint8_t>& bytes, const std::string& printerName);
  flutter::EncodableMap BuildPrinterStatusMap(const std::string& printerName);
  void PopulateDefaultStatus(flutter::EncodableMap& statusMap) const;
};

}  // namespace thermal_printer_flutter

#endif  // FLUTTER_PLUGIN_THERMAL_PRINTER_FLUTTER_PLUGIN_H_
