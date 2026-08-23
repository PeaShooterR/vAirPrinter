#import <Foundation/Foundation.h>
#import "PrintForwarder.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <string.h>
#include <unistd.h>
#include <copyfile.h>

static NSString * const SaveOnlyBehavior = @"save-only";
static NSString * const SaveAndForwardBehavior = @"save-and-forward";
static NSString * const ForwardOnlyBehavior = @"forward-only";
static NSString * const ForwardOrSaveBehavior = @"forward-or-save";

static NSString *FailureMessage(NSString *action, int errorNumber) {
    NSString *reason = [NSString stringWithUTF8String:strerror(errorNumber)] ?: @"Unknown error";
    return [NSString stringWithFormat:@"%@: %@", action, reason];
}

static void PostResult(NSString *title, BOOL success, NSString *message, NSString *path,
        NSString *forwardedPrinter) {
    NSMutableDictionary *result = [@{
        @"title": title,
        @"success": @(success),
        @"message": message ?: @""
    } mutableCopy];
    if (path.length > 0) {
        result[@"path"] = path;
        result[@"isFile"] = @YES;
    }
    if (forwardedPrinter.length > 0) result[@"forwardedPrinter"] = forwardedPrinter;
    NSString *eventDirectory = NSProcessInfo.processInfo.environment[@"AIRPDF_EVENT_DIR"];
    if (eventDirectory.length == 0) return;
    NSString *filename = [NSString stringWithFormat:@"%@.plist", NSUUID.UUID.UUIDString];
    [result writeToFile:[eventDirectory stringByAppendingPathComponent:filename] atomically:YES];
}

static void PostQueueOpenRequest(NSString *printerName) {
    NSString *eventDirectory = NSProcessInfo.processInfo.environment[@"AIRPDF_EVENT_DIR"];
    if (eventDirectory.length == 0 || printerName.length == 0) return;
    NSString *filename = [NSString stringWithFormat:@"%@.plist", NSUUID.UUID.UUIDString];
    [@{ @"openQueuePrinter": printerName }
        writeToFile:[eventDirectory stringByAppendingPathComponent:filename] atomically:YES];
}

static BOOL CopyDescriptorManual(int input, int output, NSString **errorMessage) {
    unsigned char buffer[65536];
    ssize_t count;
    while ((count = read(input, buffer, sizeof(buffer))) > 0) {
        unsigned char *cursor = buffer;
        ssize_t remaining = count;
        while (remaining > 0) {
            ssize_t written = write(output, cursor, (size_t)remaining);
            if (written < 0) {
                if (errorMessage) *errorMessage = FailureMessage(@"Unable to write the PDF", errno);
                return NO;
            }
            cursor += written;
            remaining -= written;
        }
    }
    if (count < 0) {
        if (errorMessage) *errorMessage = FailureMessage(@"Unable to read the print data", errno);
        return NO;
    }
    return YES;
}

static BOOL CopyDescriptor(int input, int output, NSString **errorMessage) {
    if (fcopyfile(input, output, NULL, COPYFILE_DATA) != 0) {
        int savedErrno = errno;
        if (savedErrno == EINVAL || savedErrno == ENOTSUP) {
            if (!CopyDescriptorManual(input, output, errorMessage)) return NO;
        } else {
            if (errorMessage) *errorMessage = FailureMessage(@"Unable to copy the PDF data", savedErrno);
            return NO;
        }
    }
    if (fsync(output) < 0) {
        if (errorMessage) *errorMessage = FailureMessage(@"Unable to finish writing the PDF", errno);
        return NO;
    }
    return YES;
}

static NSString *TemporaryCopyOfStandardInput(NSString **errorMessage) {
    NSString *templatePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vAirPrinter-XXXXXX.pdf"];
    char path[PATH_MAX];
    if (![templatePath getFileSystemRepresentation:path maxLength:sizeof(path)]) {
        if (errorMessage) *errorMessage = @"Unable to create a temporary print file path.";
        return nil;
    }
    int output = mkstemps(path, 4);
    if (output < 0) {
        if (errorMessage) *errorMessage = FailureMessage(@"Unable to create a temporary print file", errno);
        return nil;
    }
    BOOL copied = CopyDescriptor(STDIN_FILENO, output, errorMessage);
    int closeResult = close(output);
    if (!copied || closeResult < 0) {
        if (copied && errorMessage) *errorMessage = FailureMessage(@"Unable to close the temporary print file", errno);
        unlink(path);
        return nil;
    }
    return [[NSFileManager defaultManager] stringWithFileSystemRepresentation:path length:strlen(path)];
}

static NSString *UniqueOutputPath(NSString *outputDirectory, NSString *jobName, NSString *jobID, int *output) {
    for (NSInteger attempt = 1; attempt < 10000; attempt++) {
        NSString *suffix = attempt == 1 ? @"" : [NSString stringWithFormat:@"-%ld", (long)attempt];
        NSString *filename = [NSString stringWithFormat:@"%@-job_%@%@.pdf", jobName, jobID, suffix];
        NSString *path = [outputDirectory stringByAppendingPathComponent:filename];
        *output = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0644);
        if (*output >= 0) return path;
        if (errno != EEXIST) return nil;
    }
    errno = EEXIST;
    return nil;
}

static NSString *SavePDF(NSString *sourcePath, NSString *outputDirectory, NSString *jobName,
        NSString *jobID, NSString **errorMessage) {
    if (outputDirectory.length == 0) {
        if (errorMessage) *errorMessage = @"No output location is configured.";
        return nil;
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:outputDirectory
        withIntermediateDirectories:YES attributes:nil error:nil];
    int input = open(sourcePath.fileSystemRepresentation, O_RDONLY);
    if (input < 0) {
        if (errorMessage) *errorMessage = FailureMessage(@"Unable to read the print job", errno);
        return nil;
    }
    int output = -1;
    NSString *outputPath = UniqueOutputPath(outputDirectory, jobName, jobID, &output);
    if (!outputPath || output < 0) {
        int savedError = errno;
        close(input);
        if (errorMessage) *errorMessage = FailureMessage(@"Unable to create the PDF", savedError);
        return nil;
    }
    BOOL copied = CopyDescriptor(input, output, errorMessage);
    int inputCloseResult = close(input);
    int inputCloseError = errno;
    int outputCloseResult = close(output);
    int outputCloseError = errno;
    if (!copied || inputCloseResult < 0 || outputCloseResult < 0) {
        if (copied && errorMessage) {
            int savedError = inputCloseResult < 0 ? inputCloseError : outputCloseError;
            *errorMessage = FailureMessage(@"Unable to finish saving the PDF", savedError);
        }
        unlink(outputPath.fileSystemRepresentation);
        return nil;
    }
    return outputPath;
}

static NSString *SanitizedJobName(NSString *jobName) {
    NSCharacterSet *invalidCharacters = [NSCharacterSet characterSetWithCharactersInString:@"/:\\\n\r\t"];
    NSString *sanitized = [[jobName componentsSeparatedByCharactersInSet:invalidCharacters]
        componentsJoinedByString:@"_"];
    return sanitized.length > 0 ? sanitized : @"Print Job";
}

typedef enum {
    BehaviorSaveOnly,
    BehaviorSaveAndForward,
    BehaviorForwardOnly,
    BehaviorForwardOrSave,
    BehaviorUnknown
} PrintBehavior;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
        NSURL *securityURL = nil;
        NSString *encodedBookmark = environment[@"AIRPDF_OUTPUT_BOOKMARK"];
        if (encodedBookmark.length > 0) {
            NSData *bookmark = [[NSData alloc] initWithBase64EncodedString:encodedBookmark options:0];
            BOOL stale = NO;
            securityURL = [NSURL URLByResolvingBookmarkData:bookmark options:NSURLBookmarkResolutionWithSecurityScope
                relativeToURL:nil bookmarkDataIsStale:&stale error:nil];
            (void)stale;
            [securityURL startAccessingSecurityScopedResource];
        }
        NSString *outputDirectory = securityURL.path ?: environment[@"AIRPDF_OUTPUT_DIR"];
        NSString *behavior = environment[@"VAIR_PRINT_BEHAVIOR"] ?: SaveOnlyBehavior;
        PrintBehavior parsedBehavior = BehaviorUnknown;
        if ([behavior isEqualToString:SaveOnlyBehavior]) parsedBehavior = BehaviorSaveOnly;
        else if ([behavior isEqualToString:SaveAndForwardBehavior]) parsedBehavior = BehaviorSaveAndForward;
        else if ([behavior isEqualToString:ForwardOnlyBehavior]) parsedBehavior = BehaviorForwardOnly;
        else if ([behavior isEqualToString:ForwardOrSaveBehavior]) parsedBehavior = BehaviorForwardOrSave;
        NSString *forwardPrinter = environment[@"VAIR_FORWARD_PRINTER"] ?: @"";
        NSString *jobName = SanitizedJobName(environment[@"IPP_JOB_NAME"] ?: @"Print Job");
        NSString *jobID = environment[@"IPP_JOB_ID"];
        if (jobID.length == 0) jobID = [NSString stringWithFormat:@"%d", getpid()];

        BOOL temporaryInput = argc <= 1;
        NSString *inputError = nil;
        NSString *workingPath = temporaryInput ? TemporaryCopyOfStandardInput(&inputError) :
            [[NSFileManager defaultManager] stringWithFileSystemRepresentation:argv[1] length:strlen(argv[1])];
        if (workingPath.length == 0) {
            PostResult(@"Print Failed", NO, inputError ?: @"Unable to read the print job.", nil, nil);
            [securityURL stopAccessingSecurityScopedResource];
            return 1;
        }

        BOOL saveAlways = parsedBehavior == BehaviorSaveOnly ||
            parsedBehavior == BehaviorSaveAndForward;
        BOOL forward = parsedBehavior == BehaviorSaveAndForward ||
            parsedBehavior == BehaviorForwardOnly ||
            parsedBehavior == BehaviorForwardOrSave;
        NSString *savedPath = nil;
        NSString *saveError = nil;
        if (saveAlways) savedPath = SavePDF(workingPath, outputDirectory, jobName, jobID, &saveError);

        NSDictionary<NSString *, id> *forwardResult = nil;
        if (forward) forwardResult = VAPForwardPDF(workingPath, forwardPrinter, jobName);
        BOOL forwarded = [forwardResult[@"success"] boolValue];
        NSString *forwardMessage = forwardResult[@"message"] ?: @"The print job could not be forwarded.";
        if (forwarded) PostQueueOpenRequest(forwardPrinter);
        BOOL printed = forwarded;
        if (parsedBehavior == BehaviorForwardOrSave && forwarded) {
            NSDictionary<NSString *, id> *printResult = VAPWaitForPrintJob(
                forwardPrinter, [forwardResult[@"jobID"] integerValue], 300.0);
            printed = [printResult[@"success"] boolValue];
            forwardMessage = printResult[@"message"] ?: @"The print job did not complete successfully.";
        }

        if (parsedBehavior == BehaviorForwardOrSave && !printed) {
            savedPath = SavePDF(workingPath, outputDirectory, jobName, jobID, &saveError);
        }

        BOOL success = NO;
        if (parsedBehavior == BehaviorSaveOnly) {
            success = savedPath.length > 0;
            PostResult(success ? @"Print File Saved" : @"Print Failed", success,
                success ? savedPath : saveError, savedPath, nil);
        } else if (parsedBehavior == BehaviorSaveAndForward) {
            success = savedPath.length > 0 && forwarded;
            if (success) {
                PostResult(@"Print Saved and Forwarded", YES,
                    [NSString stringWithFormat:@"%@ Saved to %@", forwardMessage, savedPath], savedPath,
                    forwardPrinter);
            } else if (savedPath.length > 0) {
                PostResult(@"Printer Forwarding Failed", NO,
                    [NSString stringWithFormat:@"%@ PDF saved to %@", forwardMessage, savedPath], savedPath, nil);
            } else if (forwarded) {
                PostResult(@"PDF Saving Failed", NO,
                    [NSString stringWithFormat:@"%@ %@", saveError ?: @"Unable to save the PDF.", forwardMessage], nil,
                    forwardPrinter);
            } else {
                PostResult(@"Print Failed", NO,
                    [NSString stringWithFormat:@"%@ %@", saveError ?: @"Unable to save the PDF.", forwardMessage], nil,
                    nil);
            }
        } else if (parsedBehavior == BehaviorForwardOnly) {
            success = forwarded;
            PostResult(success ? @"Print Forwarded" : @"Printer Forwarding Failed", success,
                forwardMessage, nil, forwarded ? forwardPrinter : nil);
        } else if (parsedBehavior == BehaviorForwardOrSave) {
            success = printed;
            if (printed) {
                PostResult(@"Print Completed", YES, forwardMessage, nil, forwardPrinter);
            } else if (savedPath.length > 0) {
                PostResult(forwarded ? @"Printing Failed — PDF Saved" : @"Printer Forwarding Failed — PDF Saved", NO,
                    [NSString stringWithFormat:@"%@ PDF saved to %@", forwardMessage, savedPath], savedPath, nil);
            } else {
                PostResult(@"Print Failed", NO,
                    [NSString stringWithFormat:@"%@ %@", forwardMessage,
                        saveError ?: @"The fallback PDF could not be saved."], nil, nil);
            }
        } else {
            PostResult(@"Print Failed", NO, @"The configured print behavior is not valid.", nil, nil);
        }

        if (temporaryInput) unlink(workingPath.fileSystemRepresentation);
        [securityURL stopAccessingSecurityScopedResource];
        return success ? 0 : 1;
    }
}
