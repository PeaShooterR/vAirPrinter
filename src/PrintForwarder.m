#import "PrintForwarder.h"
#import <CoreGraphics/CoreGraphics.h>
#import <cups/cups.h>
#include <math.h>
#include <unistd.h>

static NSString *StringFromCString(const char *value) {
    return value ? [NSString stringWithUTF8String:value] : @"";
}

NSArray<NSDictionary<NSString *, NSString *> *> *VAPInstalledPrinters(void) {
    cups_dest_t *destinations = NULL;
    int count = cupsGetDests2(CUPS_HTTP_DEFAULT, &destinations);
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *printers = [NSMutableArray arrayWithCapacity:count];
    for (int index = 0; index < count; index++) {
        cups_dest_t *destination = destinations + index;
        NSString *name = StringFromCString(destination->name);
        if (name.length == 0) continue;
        const char *info = cupsGetOption("printer-info", destination->num_options, destination->options);
        NSString *displayName = StringFromCString(info);
        if (displayName.length == 0) displayName = name;
        [printers addObject:@{@"name": name, @"displayName": displayName}];
    }
    cupsFreeDests(count, destinations);
    [printers sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"displayName"] localizedCaseInsensitiveCompare:right[@"displayName"]];
    }];
    return printers;
}

static void AddMediaSize(NSMutableArray<NSDictionary<NSString *, id> *> *mediaSizes,
    NSMutableSet<NSString *> *dimensions, cups_dest_t *destination, cups_dinfo_t *info,
    cups_size_t *media) {
    if (media->width <= 0 || media->length <= 0) return;
    NSString *dimensionKey = [NSString stringWithFormat:@"%dx%d", media->width, media->length];
    if ([dimensions containsObject:dimensionKey]) return;
    const char *localizedName = cupsLocalizeDestMedia(CUPS_HTTP_DEFAULT, destination, info,
        CUPS_MEDIA_FLAGS_DEFAULT, media);
    NSString *name = StringFromCString(localizedName);
    if (name.length == 0) name = StringFromCString(media->media);
    if (name.length == 0) name = [NSString stringWithFormat:@"%g × %g mm",
        media->width / 100.0, media->length / 100.0];
    [dimensions addObject:dimensionKey];
    [mediaSizes addObject:@{
        @"name": name,
        @"width": @(media->width / 100.0),
        @"height": @(media->length / 100.0)
    }];
}

NSArray<NSDictionary<NSString *, id> *> *VAPSupportedMediaForPrinter(
    NSString *printerName, NSString **errorMessage) {
    if (printerName.length == 0) {
        if (errorMessage) *errorMessage = @"No forwarding printer is selected.";
        return nil;
    }
    cups_dest_t *destination = cupsGetNamedDest(CUPS_HTTP_DEFAULT, printerName.UTF8String, NULL);
    if (!destination) {
        if (errorMessage) *errorMessage = @"The selected printer is no longer installed.";
        return nil;
    }
    cups_dinfo_t *info = cupsCopyDestInfo(CUPS_HTTP_DEFAULT, destination);
    if (!info) {
        NSString *reason = StringFromCString(cupsLastErrorString());
        cupsFreeDests(1, destination);
        if (errorMessage) *errorMessage = reason.length ? reason :
            @"Unable to read the selected printer's capabilities.";
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *mediaSizes = [NSMutableArray array];
    NSMutableSet<NSString *> *dimensions = [NSMutableSet set];
    cups_size_t media = {0};
    if (cupsGetDestMediaDefault(CUPS_HTTP_DEFAULT, destination, info,
            CUPS_MEDIA_FLAGS_DEFAULT, &media)) {
        AddMediaSize(mediaSizes, dimensions, destination, info, &media);
    }
    int mediaCount = cupsGetDestMediaCount(CUPS_HTTP_DEFAULT, destination, info,
        CUPS_MEDIA_FLAGS_DEFAULT);
    for (int index = 0; index < mediaCount; index++) {
        if (cupsGetDestMediaByIndex(CUPS_HTTP_DEFAULT, destination, info, index,
                CUPS_MEDIA_FLAGS_DEFAULT, &media)) {
            AddMediaSize(mediaSizes, dimensions, destination, info, &media);
        }
    }
    cupsFreeDestInfo(info);
    cupsFreeDests(1, destination);
    if (mediaSizes.count == 0) {
        if (errorMessage) *errorMessage = @"The selected printer did not report any accepted paper sizes.";
        return nil;
    }
    return mediaSizes;
}

static BOOL PDFDimensions(NSString *filePath, int *width, int *height, NSString **errorMessage) {
    NSURL *url = [NSURL fileURLWithPath:filePath];
    CGPDFDocumentRef document = CGPDFDocumentCreateWithURL((__bridge CFURLRef)url);
    if (!document || CGPDFDocumentGetNumberOfPages(document) == 0) {
        if (document) CGPDFDocumentRelease(document);
        if (errorMessage) *errorMessage = @"The received document is not a readable PDF.";
        return NO;
    }
    CGPDFPageRef page = CGPDFDocumentGetPage(document, 1);
    CGRect box = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
    CGPDFDocumentRelease(document);
    if (CGRectIsEmpty(box)) {
        if (errorMessage) *errorMessage = @"The received PDF has no valid page size.";
        return NO;
    }
    *width = (int)llround(CGRectGetWidth(box) * 2540.0 / 72.0);
    *height = (int)llround(CGRectGetHeight(box) * 2540.0 / 72.0);
    return YES;
}

NSDictionary<NSString *, id> *VAPForwardPDF(NSString *filePath, NSString *printerName, NSString *jobName) {
    if (printerName.length == 0) {
        return @{@"success": @NO, @"message": @"No forwarding printer is selected."};
    }
    int width = 0;
    int height = 0;
    NSString *dimensionError = nil;
    if (!PDFDimensions(filePath, &width, &height, &dimensionError)) {
        return @{@"success": @NO, @"message": dimensionError ?: @"Unable to read the PDF page size."};
    }

    cups_dest_t *destination = cupsGetNamedDest(CUPS_HTTP_DEFAULT, printerName.UTF8String, NULL);
    if (!destination) {
        return @{@"success": @NO,
            @"message": [NSString stringWithFormat:@"The selected printer “%@” is no longer installed.", printerName]};
    }

    cups_dinfo_t *info = cupsCopyDestInfo(CUPS_HTTP_DEFAULT, destination);
    if (!info) {
        NSString *reason = StringFromCString(cupsLastErrorString());
        cupsFreeDests(1, destination);
        return @{@"success": @NO,
            @"message": reason.length ? reason : @"Unable to read the selected printer’s capabilities."};
    }

    cups_size_t media = {0};
    BOOL foundMedia = cupsGetDestMediaBySize(CUPS_HTTP_DEFAULT, destination, info, width, height,
        CUPS_MEDIA_FLAGS_DEFAULT, &media);
    if (!foundMedia) {
        foundMedia = cupsGetDestMediaDefault(CUPS_HTTP_DEFAULT, destination, info,
            CUPS_MEDIA_FLAGS_DEFAULT, &media);
    }
    if (!foundMedia || media.media[0] == '\0') {
        cupsFreeDestInfo(info);
        cupsFreeDests(1, destination);
        return @{@"success": @NO, @"message": @"The selected printer did not report an accepted paper size."};
    }

    cups_option_t *options = NULL;
    int optionCount = 0;
    optionCount = cupsAddDestMediaOptions(CUPS_HTTP_DEFAULT, destination, info, CUPS_MEDIA_FLAGS_DEFAULT,
        &media, optionCount, &options);
    if (cupsCheckDestSupported(CUPS_HTTP_DEFAULT, destination, info, "print-scaling", "fit")) {
        optionCount = cupsAddOption("print-scaling", "fit", optionCount, &options);
    } else {
        optionCount = cupsAddOption("fit-to-page", "true", optionCount, &options);
    }
    int jobID = cupsPrintFile2(CUPS_HTTP_DEFAULT, destination->name, filePath.fileSystemRepresentation,
        jobName.UTF8String, optionCount, options);
    cupsFreeOptions(optionCount, options);
    NSString *mediaName = StringFromCString(media.media);
    cupsFreeDestInfo(info);
    cupsFreeDests(1, destination);

    if (jobID <= 0) {
        NSString *reason = StringFromCString(cupsLastErrorString());
        return @{@"success": @NO,
            @"message": reason.length ? reason : @"The print job was rejected by CUPS."};
    }
    return @{
        @"success": @YES,
        @"message": [NSString stringWithFormat:@"Forwarded to %@ using %@ (job %d).",
            printerName, mediaName, jobID],
        @"media": mediaName,
        @"jobID": @(jobID)
    };
}

NSDictionary<NSString *, id> *VAPWaitForPrintJob(
    NSString *printerName, NSInteger jobID, NSTimeInterval timeout) {
    if (printerName.length == 0 || jobID <= 0) {
        return @{ @"success": @NO, @"message": @"The forwarded print job could not be monitored." };
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline timeIntervalSinceNow] > 0) {
        cups_job_t *jobs = NULL;
        int jobCount = cupsGetJobs2(CUPS_HTTP_DEFAULT, &jobs, printerName.UTF8String, 0,
            CUPS_WHICHJOBS_ALL);
        ipp_jstate_t state = 0;
        BOOL found = NO;
        for (int index = 0; index < jobCount; index++) {
            if (jobs[index].id == jobID) {
                state = jobs[index].state;
                found = YES;
                break;
            }
        }
        cupsFreeJobs(jobCount, jobs);
        if (found) {
            if (state == IPP_JSTATE_COMPLETED) {
                return @{
                    @"success": @YES,
                    @"message": [NSString stringWithFormat:@"Printed by %@ (job %ld).",
                        printerName, (long)jobID]
                };
            }
            if (state == IPP_JSTATE_CANCELED) {
                return @{ @"success": @NO, @"message": @"The print job was canceled before completion." };
            }
            if (state == IPP_JSTATE_ABORTED) {
                return @{ @"success": @NO, @"message": @"The print job was aborted by the printer or CUPS." };
            }
            if (state == IPP_JSTATE_STOPPED) {
                return @{ @"success": @NO, @"message": @"The print job stopped before completion." };
            }
        }
        usleep(500000);
    }
    return @{
        @"success": @NO,
        @"message": [NSString stringWithFormat:
            @"The print job did not complete within %.0f minutes.", timeout / 60.0]
    };
}
