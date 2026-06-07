#import "CupsPrinter.h"
#import <cups/cups.h>

static NSString *const kCupsErrorDomain = @"thermal_printer_flutter.cups";

@implementation CupsPrinter

+ (NSArray<NSDictionary<NSString *, id> *> *)listPrinters {
    NSMutableArray<NSDictionary<NSString *, id> *> *printers = [NSMutableArray array];

    cups_dest_t *dests = NULL;
    int numDests = cupsGetDests(&dests);

    for (int i = 0; i < numDests; i++) {
        cups_dest_t *dest = &dests[i];
        if (dest->name == NULL) {
            continue;
        }

        NSString *name = [NSString stringWithUTF8String:dest->name];

        // `device-uri` is usually an admin-only attribute and not exposed here,
        // so it may be empty. When it is available we use it to skip clearly
        // non-USB queues (network/ipp); otherwise we list the queue anyway,
        // matching the Windows behaviour of enumerating all system printers.
        const char *uri = cupsGetOption("device-uri", dest->num_options, dest->options);
        NSString *deviceUri = uri ? [NSString stringWithUTF8String:uri] : @"";
        if (deviceUri.length > 0 &&
            ![deviceUri hasPrefix:@"usb:"] &&
            ![deviceUri hasPrefix:@"usb://"]) {
            continue;
        }

        [printers addObject:@{
            @"name": name,
            @"usbAddress": deviceUri,
            @"type": @"usb",
            @"isConnected": @YES,
        }];
    }

    cupsFreeDests(numDests, dests);
    return printers;
}

+ (BOOL)printRawData:(NSData *)data
           toPrinter:(NSString *)printerName
               error:(NSError * _Nullable * _Nullable)error {
    if (printerName.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:kCupsErrorDomain
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Printer name is empty"}];
        }
        return NO;
    }

    const char *name = printerName.UTF8String;

    int jobId = cupsCreateJob(CUPS_HTTP_DEFAULT, name, "thermal_printer_flutter", 0, NULL);
    if (jobId == 0) {
        if (error) {
            NSString *msg = [NSString stringWithFormat:@"cupsCreateJob failed: %s", cupsLastErrorString()];
            *error = [NSError errorWithDomain:kCupsErrorDomain
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }

    http_status_t startStatus = cupsStartDocument(CUPS_HTTP_DEFAULT, name, jobId,
                                                  "document", CUPS_FORMAT_RAW, 1);
    if (startStatus != HTTP_STATUS_CONTINUE) {
        if (error) {
            NSString *msg = [NSString stringWithFormat:@"cupsStartDocument failed: %s", cupsLastErrorString()];
            *error = [NSError errorWithDomain:kCupsErrorDomain
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }

    http_status_t writeStatus = cupsWriteRequestData(CUPS_HTTP_DEFAULT,
                                                     (const char *)data.bytes,
                                                     data.length);
    // Always finish the document to avoid leaving a dangling job.
    ipp_status_t finishStatus = cupsFinishDocument(CUPS_HTTP_DEFAULT, name);

    if (writeStatus != HTTP_STATUS_CONTINUE) {
        if (error) {
            NSString *msg = [NSString stringWithFormat:@"cupsWriteRequestData failed: %s", cupsLastErrorString()];
            *error = [NSError errorWithDomain:kCupsErrorDomain
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }

    if (finishStatus != IPP_STATUS_OK) {
        if (error) {
            NSString *msg = [NSString stringWithFormat:@"cupsFinishDocument failed: %s", cupsLastErrorString()];
            *error = [NSError errorWithDomain:kCupsErrorDomain
                                         code:5
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }

    return YES;
}

+ (NSDictionary<NSString *, id> *)statusForPrinter:(NSString *)printerName {
    NSMutableDictionary<NSString *, id> *status = [@{
        @"hasStatus": @NO,
        @"hasError": @NO,
        @"isPaperOut": @NO,
        @"isPaperJam": @NO,
        @"isDoorOpen": @NO,
        @"isOffline": @NO,
        @"isPaperLow": @NO,
        @"needsUserAction": @NO,
        @"rawStatus": @0,
        @"description": @"",
    } mutableCopy];

    if (printerName.length == 0) {
        status[@"description"] = @"Printer name is empty";
        return status;
    }

    cups_dest_t *dest = cupsGetNamedDest(CUPS_HTTP_DEFAULT, printerName.UTF8String, NULL);
    if (dest == NULL) {
        status[@"description"] = @"Printer not found";
        return status;
    }

    const char *stateStr = cupsGetOption("printer-state", dest->num_options, dest->options);
    const char *reasonsStr = cupsGetOption("printer-state-reasons", dest->num_options, dest->options);

    // printer-state: 3=idle, 4=processing, 5=stopped
    int state = stateStr ? [[NSString stringWithUTF8String:stateStr] intValue] : 0;
    NSString *reasons = reasonsStr ? [NSString stringWithUTF8String:reasonsStr] : @"";

    BOOL isPaperOut = [reasons containsString:@"media-empty"] || [reasons containsString:@"media-needed"];
    BOOL isPaperLow = [reasons containsString:@"media-low"];
    BOOL isPaperJam = [reasons containsString:@"jam"];
    BOOL isDoorOpen = [reasons containsString:@"cover-open"] || [reasons containsString:@"door-open"];
    BOOL isOffline = [reasons containsString:@"offline"] || [reasons containsString:@"shutdown"] || state == 5;
    BOOL needsUserAction = isPaperOut || isPaperJam || isDoorOpen || [reasons containsString:@"error"];
    BOOL hasError = needsUserAction || isOffline;

    status[@"hasStatus"] = @YES;
    status[@"rawStatus"] = @(state);
    status[@"isPaperOut"] = @(isPaperOut);
    status[@"isPaperLow"] = @(isPaperLow || isPaperOut);
    status[@"isPaperJam"] = @(isPaperJam);
    status[@"isDoorOpen"] = @(isDoorOpen);
    status[@"isOffline"] = @(isOffline);
    status[@"needsUserAction"] = @(needsUserAction);
    status[@"hasError"] = @(hasError);

    NSMutableString *description = [NSMutableString string];
    if (isPaperOut) [description appendString:@"Out of paper. "];
    if (isPaperJam) [description appendString:@"Paper jam. "];
    if (isDoorOpen) [description appendString:@"Cover open. "];
    if (needsUserAction && !isPaperOut && !isPaperJam && !isDoorOpen) {
        [description appendString:@"User intervention required. "];
    }
    if (isOffline && !isPaperOut && !isDoorOpen) [description appendString:@"Printer offline. "];
    if (description.length == 0) [description appendString:@"Printer ready."];
    status[@"description"] = description;

    cupsFreeDests(1, dest);
    return status;
}

@end
