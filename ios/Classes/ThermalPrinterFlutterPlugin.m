#import "ThermalPrinterFlutterPlugin.h"
#if __has_include(<thermal_printer_flutter/thermal_printer_flutter-Swift.h>)
#import <thermal_printer_flutter/thermal_printer_flutter-Swift.h>
#else
// Support project import fallback if the generated compatibility header
// is not copied when this plugin is created as a library.
// https://forums.swift.org/t/swift-static-libraries-dont-copy-generated-objective-c-header/19816
#import "thermal_printer_flutter-Swift.h"
#endif

@implementation ThermalPrinterFlutterPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [SwiftThermalPrinterFlutterPlugin registerWithRegistrar:registrar];
}
@end 