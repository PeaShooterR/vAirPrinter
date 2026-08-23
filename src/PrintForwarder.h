#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, NSString *> *> *VAPInstalledPrinters(void);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> * _Nullable VAPSupportedMediaForPrinter(
    NSString *printerName, NSString * _Nullable * _Nullable errorMessage);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *VAPForwardPDF(
    NSString *filePath, NSString *printerName, NSString *jobName);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *VAPWaitForPrintJob(
    NSString *printerName, NSInteger jobID, NSTimeInterval timeout);

NS_ASSUME_NONNULL_END
