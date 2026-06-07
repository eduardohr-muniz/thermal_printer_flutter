#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C wrapper around the system CUPS C API.
///
/// USB thermal printing on macOS goes through the standard print system (CUPS)
/// instead of raw IOKit USB access. This mirrors how the Windows implementation
/// uses the print spooler: a printer must be installed in
/// System Settings > Printers (a Generic / raw queue works) and we send the
/// ESC/POS bytes straight to that queue using the `application/vnd.cups-raw`
/// format so CUPS does not apply any filtering.
@interface CupsPrinter : NSObject

/// Lists the printer queues installed on the system.
///
/// Each entry is a dictionary compatible with the Dart `Printer` model:
/// `{ "name": String, "usbAddress": String, "type": "usb", "isConnected": Bool }`.
+ (NSArray<NSDictionary<NSString *, id> *> *)listPrinters;

/// Sends raw bytes to the named CUPS queue. Returns YES on success.
/// On failure, `error` (if provided) describes what went wrong.
+ (BOOL)printRawData:(NSData *)data
           toPrinter:(NSString *)printerName
               error:(NSError * _Nullable * _Nullable)error;

/// Queries the CUPS state of the named queue.
///
/// Returns a dictionary compatible with the Dart `PrinterStatus` model:
/// `{ hasStatus, hasError, isPaperOut, isPaperJam, isDoorOpen, isOffline,
///    isPaperLow, needsUserAction, rawStatus, description }`.
+ (NSDictionary<NSString *, id> *)statusForPrinter:(NSString *)printerName;

@end

NS_ASSUME_NONNULL_END
