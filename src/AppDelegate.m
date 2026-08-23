#import "AppDelegate.h"
#import "PrintForwarder.h"
#import <cups/pwg.h>
#import <libproc.h>
#include <math.h>
#include <signal.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

static NSString * const OutputDirectoryKey = @"OutputDirectory";
static NSString * const OutputBookmarkKey = @"OutputDirectoryBookmark";
static NSString * const OutputConfiguredKey = @"OutputDirectoryConfigured";
static NSString * const PrinterNameKey = @"PrinterName";
static NSString * const PrinterPortKey = @"PrinterPort";
static NSString * const MediaSizesKey = @"MediaSizes";
static NSString * const PDFMediaSizesKey = @"PDFMediaSizes";
static NSString * const MediaSizesLockedKey = @"MediaSizesLocked";
static NSString * const HasLaunchedKey = @"HasLaunched";
static NSString * const PrinterWasRunningKey = @"PrinterWasRunning";
static NSString * const PrinterProcessIDKey = @"PrinterProcessID";
static NSString * const PrintBehaviorKey = @"PrintBehavior";
static NSString * const ForwardPrinterKey = @"ForwardPrinter";
static NSString * const OpenQueueAfterForwardingKey = @"OpenQueueAfterForwarding";
static NSString * const SaveOnlyBehavior = @"save-only";
static NSString * const SaveAndForwardBehavior = @"save-and-forward";
static NSString * const ForwardOnlyBehavior = @"forward-only";
static NSString * const ForwardOrSaveBehavior = @"forward-or-save";
static const double kMMToPoints = 72.0 / 25.4;

@interface AppDelegate ()
@property NSStatusItem *statusItem;
@property NSMenuItem *statusMenuItem;
@property NSMenuItem *toggleMenuItem;
@property NSWindow *settingsWindow;
@property NSTextField *printerNameField;
@property NSTextField *portField;
@property NSTextField *outputField;
@property NSPopUpButton *printBehaviorPopup;
@property NSPopUpButton *forwardPrinterPopup;
@property NSTextField *forwardPrinterLabel;
@property NSButton *openQueueCheckbox;
@property NSTableView *mediaTable;
@property NSSegmentedControl *mediaActions;
@property NSButton *mediaLockButton;
@property NSButton *resetMediaButton;
@property NSMutableArray<NSMutableDictionary *> *mediaSizes;
@property NSMutableArray<NSMutableDictionary *> *pdfMediaSizes;
@property NSTask *printerTask;
@property NSPipe *printerErrorPipe;
@property NSInteger intentionallyStoppedPID;
@property NSURL *activeOutputURL;
@property dispatch_source_t eventSource;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSImage *appIcon = [NSImage imageNamed:@"AppIcon"];
    if (appIcon) NSApp.applicationIconImage = appIcon;
    UNUserNotificationCenter *notificationCenter = UNUserNotificationCenter.currentNotificationCenter;
    notificationCenter.delegate = self;
    [notificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
        completionHandler:^(BOOL granted, NSError *error) { (void)granted; (void)error; }];
    [self registerDefaults];
    [self terminateStalePrinterProcess];
    [self restoreOutputBookmark];
    [self loadSettings];
    [self buildStatusMenu];
    NSString *eventsDir = [[self applicationSupportDirectory] stringByAppendingPathComponent:@"Events"];
    [[NSFileManager defaultManager] createDirectoryAtPath:eventsDir withIntermediateDirectories:YES attributes:nil error:nil];
    int evtFd = open(eventsDir.fileSystemRepresentation, O_EVTONLY);
    if (evtFd >= 0) {
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, evtFd,
            DISPATCH_VNODE_WRITE, dispatch_get_main_queue());
        dispatch_source_set_event_handler(src, ^{ [self pollPrintResults:nil]; });
        dispatch_source_set_cancel_handler(src, ^{ close(evtFd); });
        dispatch_resume(src);
        self.eventSource = src;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL hasLaunched = [defaults boolForKey:HasLaunchedKey];
    if (hasLaunched && [defaults boolForKey:PrinterWasRunningKey]) [self startPrinter:nil];
    [defaults setBool:YES forKey:HasLaunchedKey];
    [defaults synchronize];
}

- (void)terminateStalePrinterProcess {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    pid_t pid = (pid_t)[defaults integerForKey:PrinterProcessIDKey];
    [defaults removeObjectForKey:PrinterProcessIDKey];
    if (pid <= 1) return;
    char executablePath[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, executablePath, sizeof(executablePath)) <= 0) return;
    if (strcmp(executablePath, "/usr/bin/ippeveprinter") != 0) return;
    kill(pid, SIGTERM);
    for (NSInteger attempt = 0; attempt < 50 && kill(pid, 0) == 0; attempt++) usleep(20000);
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:self.printerTask.running forKey:PrinterWasRunningKey];
    [defaults synchronize];
    [self stopPrinter:nil];
    [self.activeOutputURL stopAccessingSecurityScopedResource];
    if (self.eventSource) dispatch_source_cancel(self.eventSource);
}

- (void)pollPrintResults:(NSTimer *)timer {
    (void)timer;
    NSString *eventDirectory = [[self applicationSupportDirectory] stringByAppendingPathComponent:@"Events"];
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:eventDirectory error:nil];
    for (NSString *name in files) {
        if (![name.pathExtension isEqualToString:@"plist"]) continue;
        NSString *path = [eventDirectory stringByAppendingPathComponent:name];
        NSDictionary *result = [NSDictionary dictionaryWithContentsOfFile:path];
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        NSString *queuePrinter = result[@"openQueuePrinter"];
        if (queuePrinter.length > 0) {
            if ([[NSUserDefaults standardUserDefaults] boolForKey:OpenQueueAfterForwardingKey]) {
                [self openPrinterQueueForPrinter:queuePrinter];
            }
        } else if (result) {
            [self showPrintResult:result];
        }
    }
}

- (void)showPrintResult:(NSDictionary *)result {
    BOOL success = [result[@"success"] boolValue];
    NSString *message = result[@"message"] ?: @"Unknown error";
    NSString *path = result[@"path"];
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = result[@"title"] ?: (success ? @"Print Completed" : @"Print Failed");
    content.body = message;
    content.sound = UNNotificationSound.defaultSound;
    if (path) content.userInfo = @{@"path": path, @"isFile": result[@"isFile"] ?: @YES};
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString
        content:content trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
}

- (void)openPrinterQueueForPrinter:(NSString *)printerName {
    NSUserDefaults *printCenterDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.apple.printcenter"];
    [printCenterDefaults setObject:printerName forKey:@"com.apple.printcenter.selectedPrinter"];
    [printCenterDefaults synchronize];
    NSURL *printCenterURL = [[NSWorkspace sharedWorkspace]
        URLForApplicationWithBundleIdentifier:@"com.apple.printcenter"];
    if (!printCenterURL) return;
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = YES;
    configuration.addsToRecentItems = NO;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:printCenterURL configuration:configuration
        completionHandler:nil];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
        willPresentNotification:(UNNotification *)notification
          withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       didReceiveNotificationResponse:(UNNotificationResponse *)response
          withCompletionHandler:(void (^)(void))completionHandler {
    NSDictionary *userInfo = response.notification.request.content.userInfo;
    NSString *path = userInfo[@"path"];
    BOOL isFile = [userInfo[@"isFile"] boolValue];
    if ([response.actionIdentifier isEqualToString:UNNotificationDefaultActionIdentifier] && path.length > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURL *url = [NSURL fileURLWithPath:path isDirectory:!isFile];
            if (isFile) [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
            else [[NSWorkspace sharedWorkspace] openURL:url];
        });
    }
    completionHandler();
}

- (NSArray<NSMutableDictionary *> *)defaultMediaSizes {
    return @[
        [self media:@"A3" width:297 height:420], [self media:@"A4" width:210 height:297],
        [self media:@"A5" width:148 height:210], [self media:@"A6" width:105 height:148],
        [self media:@"A7" width:74 height:105], [self media:@"ISO B4" width:250 height:353],
        [self media:@"ISO B5" width:176 height:250], [self media:@"ISO B6" width:125 height:176],
        [self media:@"ISO B7" width:88 height:125], [self media:@"JIS B4" width:257 height:364],
        [self media:@"JIS B5" width:182 height:257], [self media:@"JIS B6" width:128 height:182],
        [self media:@"JIS B7" width:91 height:128], [self media:@"Letter" width:215.9 height:279.4],
        [self media:@"Legal" width:215.9 height:355.6], [self media:@"Tabloid" width:279.4 height:431.8],
        [self media:@"Ledger" width:431.8 height:279.4], [self media:@"Executive" width:184.15 height:266.7],
        [self media:@"Statement" width:139.7 height:215.9], [self media:@"Folio" width:210 height:330],
        [self media:@"Photo 3.5x5" width:88.9 height:127], [self media:@"Photo 4x6" width:101.6 height:152.4],
        [self media:@"Photo 5x7" width:127 height:177.8], [self media:@"Photo 6x8" width:152.4 height:203.2],
        [self media:@"Photo 8x10" width:203.2 height:254], [self media:@"Photo 10x15 cm" width:100 height:150],
        [self media:@"Square 5x5" width:127 height:127], [self media:@"Square 6x6" width:152.4 height:152.4],
        [self media:@"Hagaki" width:100 height:148]
    ];
}

- (void)registerDefaults {
    NSString *defaultOutput = NSHomeDirectory();
    NSArray<NSMutableDictionary *> *sizes = [self defaultMediaSizes];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{
        OutputDirectoryKey: defaultOutput,
        OutputConfiguredKey: @NO,
        PrinterNameKey: @"vAirPrinter",
        PrinterPortKey: @8631,
        MediaSizesKey: sizes,
        PDFMediaSizesKey: sizes,
        MediaSizesLockedKey: @NO,
        PrintBehaviorKey: SaveOnlyBehavior,
        ForwardPrinterKey: @"",
        OpenQueueAfterForwardingKey: @NO,
        HasLaunchedKey: @NO,
        PrinterWasRunningKey: @NO
    }];
    if (![defaults boolForKey:HasLaunchedKey]) {
        [defaults setObject:sizes forKey:MediaSizesKey];
        [defaults setObject:[[NSArray alloc] initWithArray:sizes copyItems:YES]
            forKey:PDFMediaSizesKey];
        [defaults setBool:NO forKey:MediaSizesLockedKey];
        [defaults synchronize];
    }
}

- (void)restoreOutputBookmark {
    NSData *bookmark = [[NSUserDefaults standardUserDefaults] dataForKey:OutputBookmarkKey];
    if (!bookmark) return;
    BOOL stale = NO;
    NSError *error = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
        options:NSURLBookmarkResolutionWithSecurityScope | NSURLBookmarkResolutionWithoutUI
        relativeToURL:nil bookmarkDataIsStale:&stale error:&error];
    if (!url || error) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults removeObjectForKey:OutputBookmarkKey];
        [defaults setObject:NSHomeDirectory() forKey:OutputDirectoryKey];
        return;
    }
    [url startAccessingSecurityScopedResource];
    self.activeOutputURL = url;
    [[NSUserDefaults standardUserDefaults] setObject:url.path forKey:OutputDirectoryKey];
    if (stale) (void)[self saveOutputBookmark:url];
}

- (BOOL)saveOutputBookmark:(NSURL *)url {
    NSError *error = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
        includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
    if (!bookmark || error) return NO;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:bookmark forKey:OutputBookmarkKey];
    [defaults setObject:url.path forKey:OutputDirectoryKey];
    return YES;
}

- (void)requestOutputAccessAndStart {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.canCreateDirectories = YES;
    panel.prompt = @"Choose";
    panel.message = @"Choose where to save printed files. You can change this later in Settings.";
    panel.directoryURL = [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
    [NSApp activateIgnoringOtherApps:YES];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([panel runModal] == NSModalResponseOK && [self saveOutputBookmark:panel.URL]) {
        [self.activeOutputURL stopAccessingSecurityScopedResource];
        [panel.URL startAccessingSecurityScopedResource];
        self.activeOutputURL = panel.URL;
    } else {
        [self.activeOutputURL stopAccessingSecurityScopedResource];
        self.activeOutputURL = nil;
        [defaults removeObjectForKey:OutputBookmarkKey];
        [defaults setObject:NSHomeDirectory() forKey:OutputDirectoryKey];
    }
    [defaults setBool:YES forKey:OutputConfiguredKey];
    [defaults synchronize];
    [self startPrinter:nil];
}

- (NSMutableDictionary *)media:(NSString *)name width:(double)width height:(double)height {
    return [@{@"name": name, @"width": @(width), @"height": @(height)} mutableCopy];
}

- (void)loadSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *stored = [defaults arrayForKey:MediaSizesKey];
    NSArray *storedPDF = [defaults arrayForKey:PDFMediaSizesKey];
    if (stored.count == 0) stored = [self defaultMediaSizes];
    if (storedPDF.count == 0) storedPDF = [self defaultMediaSizes];
    self.mediaSizes = [self mutableMediaSizesFromArray:stored];
    self.pdfMediaSizes = [self mutableMediaSizesFromArray:storedPDF];
}

- (NSMutableArray<NSMutableDictionary *> *)mutableMediaSizesFromArray:(NSArray *)sizes {
    NSMutableArray<NSMutableDictionary *> *copy = [NSMutableArray arrayWithCapacity:sizes.count];
    for (NSDictionary *item in sizes) [copy addObject:[item mutableCopy]];
    return copy;
}

- (void)buildStatusMenu {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"printer.fill" accessibilityDescription:@"vAirPrinter"];
    NSMenu *menu = [NSMenu new];
    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Stopped" action:nil keyEquivalent:@""];
    self.statusMenuItem.enabled = NO;
    [menu addItem:self.statusMenuItem];
    [menu addItem:[NSMenuItem separatorItem]];
    self.toggleMenuItem = [[NSMenuItem alloc] initWithTitle:@"Start Printer" action:@selector(togglePrinter:) keyEquivalent:@""];
    self.toggleMenuItem.target = self;
    [menu addItem:self.toggleMenuItem];
    NSMenuItem *settings = [[NSMenuItem alloc] initWithTitle:@"Settings…" action:@selector(showSettings:) keyEquivalent:@""];
    settings.target = self;
    [menu addItem:settings];
    NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:@"Open Output Folder" action:@selector(openOutputFolder:) keyEquivalent:@""];
    open.target = self;
    [menu addItem:open];
    NSMenuItem *about = [[NSMenuItem alloc] initWithTitle:@"About vAirPrinter" action:@selector(showAbout:) keyEquivalent:@""];
    about.target = self;
    [menu addItem:about];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@""];
    quit.target = NSApp;
    [menu addItem:quit];
    self.statusItem.menu = menu;
}

- (void)showAbout:(id)sender {
    NSDictionary *options = @{
        NSAboutPanelOptionApplicationName: @"vAirPrinter",
        NSAboutPanelOptionApplicationVersion: @"0.1.0",
        NSAboutPanelOptionCredits: [[NSAttributedString alloc] initWithString:
            @"https://github.com/PeaShooterR/vAirPrinter"]
    };
    [NSApp orderFrontStandardAboutPanelWithOptions:options];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)togglePrinter:(id)sender {
    if (self.printerTask.running) {
        [self stopPrinter:nil];
    } else if (![[NSUserDefaults standardUserDefaults] boolForKey:OutputConfiguredKey]) {
        [self requestOutputAccessAndStart];
    } else {
        [self startPrinter:nil];
    }
}

- (NSString *)applicationSupportDirectory {
    NSURL *base = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [[base URLByAppendingPathComponent:@"vAirPrinter" isDirectory:YES] path];
}

- (void)startPrinter:(id)sender {
    if (self.printerTask.running) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *output = [defaults stringForKey:OutputDirectoryKey];
    NSString *support = [self applicationSupportDirectory];
    NSString *spool = [support stringByAppendingPathComponent:@"Spool"];
    NSString *events = [support stringByAppendingPathComponent:@"Events"];
    [fm createDirectoryAtPath:output withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:spool withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:events withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *ppd = [support stringByAppendingPathComponent:@"vAirPrinter.ppd"];
    if (![self writePPD:ppd]) return;

    NSString *passthrough = [[[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Contents/Helpers"] stringByAppendingPathComponent:@"PDFPassthrough"];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:passthrough]) return;
    NSString *name = [defaults stringForKey:PrinterNameKey];
    NSString *port = [NSString stringWithFormat:@"%ld", (long)[defaults integerForKey:PrinterPortKey]];
    self.printerTask = [NSTask new];
    self.printerTask.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ippeveprinter"];
    self.printerTask.arguments = @[@"-D", @"/dev/null", @"-d", spool,
        @"-F", @"application/pdf", @"-P", ppd,
        @"-c", passthrough, @"-p", port, @"-r", @"_universal", name];
    NSMutableDictionary<NSString *, NSString *> *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"AIRPDF_OUTPUT_DIR"] = output;
    environment[@"AIRPDF_EVENT_DIR"] = events;
    environment[@"VAIR_PRINT_BEHAVIOR"] = [defaults stringForKey:PrintBehaviorKey];
    environment[@"VAIR_FORWARD_PRINTER"] = [defaults stringForKey:ForwardPrinterKey];
    NSData *bookmark = [defaults dataForKey:OutputBookmarkKey];
    if (bookmark) environment[@"AIRPDF_OUTPUT_BOOKMARK"] = [bookmark base64EncodedStringWithOptions:0];
    self.printerTask.environment = environment;
    self.printerTask.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    self.printerErrorPipe = [NSPipe pipe];
    self.printerTask.standardError = self.printerErrorPipe;
    NSFileHandle *errorHandle = self.printerErrorPipe.fileHandleForReading;
    __weak typeof(self) weakSelf = self;
    self.printerTask.terminationHandler = ^(NSTask *task) {
        NSData *errorData = [errorHandle readDataToEndOfFile];
        NSString *errorText = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        errorText = [errorText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        pid_t pid = task.processIdentifier;
        int status = task.terminationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
            if ([defaults integerForKey:PrinterProcessIDKey] == pid) [defaults removeObjectForKey:PrinterProcessIDKey];
            [defaults synchronize];
            BOOL expected = weakSelf.intentionallyStoppedPID == pid;
            if (expected) weakSelf.intentionallyStoppedPID = 0;
            if (weakSelf.printerTask == task) {
                weakSelf.printerTask = nil;
                weakSelf.printerErrorPipe = nil;
                [weakSelf updateStatus:NO];
            }
            if (!expected) {
                NSString *reason = errorText.length > 0 ? errorText :
                    [NSString stringWithFormat:@"The printer service exited with status %d.", status];
                [weakSelf showPrinterServiceError:reason];
            }
        });
    };
    NSError *error = nil;
    if ([self.printerTask launchAndReturnError:&error]) {
        [defaults setInteger:self.printerTask.processIdentifier forKey:PrinterProcessIDKey];
        [defaults synchronize];
        [self updateStatus:YES];
        [self configureReadyMediaOnPort:port.integerValue];
    } else {
        self.printerTask = nil;
        self.printerErrorPipe = nil;
        [self updateStatus:NO];
        [self showPrinterServiceError:error.localizedDescription ?: @"The printer service could not be started."];
    }
}

- (NSArray<NSString *> *)mediaKeywords {
    NSMutableArray<NSString *> *keywords = [NSMutableArray arrayWithCapacity:self.mediaSizes.count];
    NSUInteger formPathLength = @"/media?".length;
    const NSUInteger maximumFormPathLength = 1000;
    for (NSDictionary *media in self.mediaSizes) {
        int width = (int)llround([media[@"width"] doubleValue] * 100.0);
        int height = (int)llround([media[@"height"] doubleValue] * 100.0);
        pwg_media_t *pwg = pwgMediaForSize(width, height);
        if (!pwg || !pwg->pwg) continue;
        NSString *keyword = [NSString stringWithUTF8String:pwg->pwg];
        NSUInteger index = keywords.count;
        NSString *fields = [NSString stringWithFormat:@"%@size%lu=%@&level%lu=-2",
            index == 0 ? @"" : @"&", (unsigned long)index, keyword, (unsigned long)index];
        if (formPathLength + fields.length > maximumFormPathLength) break;
        formPathLength += fields.length;
        [keywords addObject:keyword];
    }
    return keywords;
}

- (void)configureReadyMediaOnPort:(NSInteger)port {
    NSArray<NSString *> *keywords = [self mediaKeywords];
    if (keywords.count == 0) return;
    NSURLComponents *components = [NSURLComponents componentsWithString:
        [NSString stringWithFormat:@"http://127.0.0.1:%ld/media", (long)port]];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithCapacity:keywords.count * 2];
    [keywords enumerateObjectsUsingBlock:^(NSString *keyword, NSUInteger index, BOOL *stop) {
        (void)stop;
        [items addObject:[NSURLQueryItem queryItemWithName:[NSString stringWithFormat:@"size%lu", (unsigned long)index]
            value:keyword]];
        [items addObject:[NSURLQueryItem queryItemWithName:[NSString stringWithFormat:@"level%lu", (unsigned long)index]
            value:@"-2"]];
    }];
    components.queryItems = items;
    NSURL *url = components.URL;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (NSInteger attempt = 0; attempt < 50; attempt++) {
            if ([NSData dataWithContentsOfURL:url options:0 error:nil]) return;
            usleep(100000);
        }
    });
}

- (void)showPrinterServiceError:(NSString *)reason {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Printer Service Failed";
    alert.informativeText = reason;
    [alert runModal];
}

- (void)stopPrinter:(id)sender {
    if (self.printerTask.running) {
        self.intentionallyStoppedPID = self.printerTask.processIdentifier;
        [self.printerTask terminate];
        [self.printerTask waitUntilExit];
    }
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:PrinterProcessIDKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    self.printerTask = nil;
    self.printerErrorPipe = nil;
    [self updateStatus:NO];
}

- (void)updateStatus:(BOOL)running {
    NSInteger port = [[NSUserDefaults standardUserDefaults] integerForKey:PrinterPortKey];
    self.statusMenuItem.title = running ? [NSString stringWithFormat:@"Printer Running — Port %ld", (long)port] : @"Printer Stopped";
    self.toggleMenuItem.title = running ? @"Stop Printer" : @"Start Printer";
}

- (BOOL)writePPD:(NSString *)path {
    if (self.mediaSizes.count == 0) return NO;
    NSMutableArray<NSString *> *mediaKeys = [NSMutableArray arrayWithCapacity:self.mediaSizes.count];
    NSMutableSet<NSString *> *usedKeys = [NSMutableSet set];
    NSInteger keyIndex = 0;
    for (NSDictionary *media in self.mediaSizes) {
        NSString *baseKey = [self ppdKey:media[@"name"] index:keyIndex];
        NSString *key = baseKey;
        while ([usedKeys containsObject:key]) key = [baseKey stringByAppendingFormat:@"%ld", (long)keyIndex];
        [usedKeys addObject:key];
        [mediaKeys addObject:key];
        keyIndex++;
    }
    NSMutableString *ppd = [NSMutableString stringWithString:
        @"*PPD-Adobe: \"4.3\"\n*FormatVersion: \"4.3\"\n*FileVersion: \"1.0\"\n"
        "*LanguageVersion: English\n*LanguageEncoding: ISOLatin1\n*PCFileName: \"AIRPDF.PPD\"\n"
        "*Manufacturer: \"vAirPrinter\"\n*Product: \"(vAirPrinter)\"\n*ModelName: \"vAirPrinter\"\n"
        "*NickName: \"vAirPrinter\"\n*ShortNickName: \"vAirPrinter\"\n*PSVersion: \"(3010.000) 0\"\n*LanguageLevel: \"3\"\n"
        "*ColorDevice: True\n*DefaultColorSpace: RGB\n*FileSystem: False\n*Throughput: \"10\"\n"
        "*OpenUI *PageSize/Page Size: PickOne\n*OrderDependency: 10 AnySetup *PageSize\n"];
    NSString *defaultKey = mediaKeys.firstObject;
    NSUInteger mediaCount = self.mediaSizes.count;
    NSMutableArray<NSNumber *> *widthsPt = [NSMutableArray arrayWithCapacity:mediaCount];
    NSMutableArray<NSNumber *> *heightsPt = [NSMutableArray arrayWithCapacity:mediaCount];
    for (NSDictionary *media in self.mediaSizes) {
        [widthsPt addObject:@([media[@"width"] doubleValue] * kMMToPoints)];
        [heightsPt addObject:@([media[@"height"] doubleValue] * kMMToPoints)];
    }
    [ppd appendFormat:@"*DefaultPageSize: %@\n", defaultKey];
    for (NSUInteger i = 0; i < mediaCount; i++) {
        double w = widthsPt[i].doubleValue, h = heightsPt[i].doubleValue;
        [ppd appendFormat:@"*PageSize %@/%@: \"<</PageSize[%.2f %.2f]/ImagingBBox null>>setpagedevice\"\n", mediaKeys[i], self.mediaSizes[i][@"name"], w, h];
    }
    [ppd appendString:@"*CloseUI: *PageSize\n"];
    [ppd appendFormat:@"*OpenUI *PageRegion/Page Region: PickOne\n*OrderDependency: 10 AnySetup *PageRegion\n*DefaultPageRegion: %@\n", defaultKey];
    for (NSUInteger i = 0; i < mediaCount; i++) {
        double w = widthsPt[i].doubleValue, h = heightsPt[i].doubleValue;
        [ppd appendFormat:@"*PageRegion %@/%@: \"<</PageSize[%.2f %.2f]/ImagingBBox null>>setpagedevice\"\n", mediaKeys[i], self.mediaSizes[i][@"name"], w, h];
    }
    [ppd appendFormat:@"*CloseUI: *PageRegion\n*DefaultImageableArea: %@\n*DefaultPaperDimension: %@\n", defaultKey, defaultKey];
    for (NSUInteger i = 0; i < mediaCount; i++) {
        double w = widthsPt[i].doubleValue, h = heightsPt[i].doubleValue;
        [ppd appendFormat:@"*ImageableArea %@/%@: \"0 0 %.2f %.2f\"\n", mediaKeys[i], self.mediaSizes[i][@"name"], w, h];
        [ppd appendFormat:@"*PaperDimension %@/%@: \"%.2f %.2f\"\n", mediaKeys[i], self.mediaSizes[i][@"name"], w, h];
    }
    [ppd appendString:@"*OpenUI *InputSlot/Media Source: PickOne\n*OrderDependency: 20 AnySetup *InputSlot\n*DefaultInputSlot: Tray1\n"];
    NSUInteger readyMediaCount = [self mediaKeywords].count;
    for (NSUInteger tray = 0; tray < readyMediaCount; tray++) {
        [ppd appendFormat:@"*InputSlot Tray%lu/Virtual Tray %lu: \"\"\n",
            (unsigned long)tray + 1, (unsigned long)tray + 1];
    }
    [ppd appendString:@"*CloseUI: *InputSlot\n"];
    return [ppd writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (NSString *)ppdKey:(NSString *)name index:(NSInteger)index {
    NSCharacterSet *invalid = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSString *key = [[name componentsSeparatedByCharactersInSet:invalid] componentsJoinedByString:@""];
    return key.length ? key : [NSString stringWithFormat:@"Media%ld", (long)index];
}

- (void)showSettings:(id)sender {
    if (!self.settingsWindow) [self buildSettingsWindow];
    self.printerNameField.stringValue = [[NSUserDefaults standardUserDefaults] stringForKey:PrinterNameKey];
    self.portField.stringValue = [NSString stringWithFormat:@"%ld",
        (long)[[NSUserDefaults standardUserDefaults] integerForKey:PrinterPortKey]];
    self.outputField.stringValue = [[NSUserDefaults standardUserDefaults] stringForKey:OutputDirectoryKey];
    [self selectPrintBehavior:[[NSUserDefaults standardUserDefaults] stringForKey:PrintBehaviorKey]];
    self.openQueueCheckbox.state = [[NSUserDefaults standardUserDefaults]
        boolForKey:OpenQueueAfterForwardingKey] ? NSControlStateValueOn : NSControlStateValueOff;
    [self reloadForwardingPrinters];
    [self updateForwardingControls];
    [self updateMediaLockControls];
    [self.mediaTable reloadData];
    [NSApp activateIgnoringOtherApps:YES];
    [self.settingsWindow makeKeyAndOrderFront:nil];
}

- (void)buildSettingsWindow {
    self.settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 620, 540)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.settingsWindow.title = @"vAirPrinter Settings";
    self.settingsWindow.releasedWhenClosed = NO;
    self.settingsWindow.delegate = self;
    [self.settingsWindow center];
    NSView *view = self.settingsWindow.contentView;

    NSTextField *nameLabel = [NSTextField labelWithString:@"Printer name:"];
    nameLabel.frame = NSMakeRect(20, 494, 100, 24); [view addSubview:nameLabel];
    self.printerNameField = [[NSTextField alloc] initWithFrame:NSMakeRect(125, 492, 280, 26)];
    self.printerNameField.delegate = self;
    [view addSubview:self.printerNameField];
    NSTextField *portLabel = [NSTextField labelWithString:@"Port:"];
    portLabel.frame = NSMakeRect(425, 494, 40, 24); [view addSubview:portLabel];
    self.portField = [[NSTextField alloc] initWithFrame:NSMakeRect(470, 492, 130, 26)];
    NSNumberFormatter *portFormatter = [NSNumberFormatter new];
    portFormatter.allowsFloats = NO;
    portFormatter.usesGroupingSeparator = NO;
    portFormatter.minimum = @1024;
    portFormatter.maximum = @65535;
    self.portField.formatter = portFormatter;
    self.portField.delegate = self;
    [view addSubview:self.portField];
    NSTextField *folderLabel = [NSTextField labelWithString:@"Save PDFs to:"];
    folderLabel.frame = NSMakeRect(20, 454, 100, 24); [view addSubview:folderLabel];
    self.outputField = [[NSTextField alloc] initWithFrame:NSMakeRect(125, 452, 385, 26)];
    self.outputField.editable = NO; [view addSubview:self.outputField];
    NSButton *choose = [NSButton buttonWithTitle:@"Choose…" target:self action:@selector(chooseOutput:)];
    choose.frame = NSMakeRect(515, 451, 85, 28); [view addSubview:choose];

    NSTextField *behaviorLabel = [NSTextField labelWithString:@"On receiving a job:"];
    behaviorLabel.frame = NSMakeRect(20, 414, 120, 24); [view addSubview:behaviorLabel];
    self.printBehaviorPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(145, 410, 455, 30) pullsDown:NO];
    for (NSArray<NSString *> *option in @[
        @[@"Save PDF only", SaveOnlyBehavior],
        @[@"Save PDF and forward to printer", SaveAndForwardBehavior],
        @[@"Forward to printer only", ForwardOnlyBehavior],
        @[@"Forward to printer save PDF if forward or print fails", ForwardOrSaveBehavior]
    ]) {
        [self.printBehaviorPopup addItemWithTitle:option[0]];
        self.printBehaviorPopup.lastItem.representedObject = option[1];
    }
    self.printBehaviorPopup.target = self;
    self.printBehaviorPopup.action = @selector(printBehaviorChanged:);
    [view addSubview:self.printBehaviorPopup];

    self.forwardPrinterLabel = [NSTextField labelWithString:@"Forward to:"];
    self.forwardPrinterLabel.frame = NSMakeRect(20, 374, 120, 24); [view addSubview:self.forwardPrinterLabel];
    self.forwardPrinterPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(145, 370, 455, 30) pullsDown:NO];
    self.forwardPrinterPopup.target = self;
    self.forwardPrinterPopup.action = @selector(forwardPrinterChanged:);
    [view addSubview:self.forwardPrinterPopup];
    self.openQueueCheckbox = [NSButton checkboxWithTitle:@"Open queue after forwarding"
        target:self action:@selector(openQueueSettingChanged:)];
    self.openQueueCheckbox.frame = NSMakeRect(400, 334, 270, 26);
    [view addSubview:self.openQueueCheckbox];
    NSTextField *mediaLabel = [NSTextField labelWithString:@"Accepted paper sizes (millimetres):"];
    mediaLabel.frame = NSMakeRect(20, 307, 300, 24); [view addSubview:mediaLabel];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 70, 580, 235)];
    scroll.hasVerticalScroller = YES; scroll.borderType = NSBezelBorder;
    self.mediaTable = [[NSTableView alloc] initWithFrame:scroll.bounds];
    for (NSArray *spec in @[@[@"name", @"Name", @300], @[@"width", @"Width", @120], @[@"height", @"Height", @120]]) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
        column.title = spec[1]; column.width = [spec[2] doubleValue]; column.editable = YES;
        [self.mediaTable addTableColumn:column];
    }
    self.mediaTable.delegate = self; self.mediaTable.dataSource = self;
    scroll.documentView = self.mediaTable; [view addSubview:scroll];
    self.mediaActions = [NSSegmentedControl segmentedControlWithLabels:@[@"+", @"−"]
        trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(changeMedia:)];
    self.mediaActions.frame = NSMakeRect(20, 32, 72, 28);
    self.mediaActions.segmentStyle = NSSegmentStyleRounded;
    [view addSubview:self.mediaActions];
    self.mediaLockButton = [NSButton buttonWithImage:
        [NSImage imageWithSystemSymbolName:@"lock.open" accessibilityDescription:@"Lock paper sizes"]
        target:self action:@selector(toggleMediaLock:)];
    self.mediaLockButton.frame = NSMakeRect(100, 32, 36, 28);
    self.mediaLockButton.bezelStyle = NSBezelStyleTexturedRounded;
    [view addSubview:self.mediaLockButton];
    self.resetMediaButton = [NSButton buttonWithTitle:@"Reset" target:self
        action:@selector(resetMediaSizes:)];
    self.resetMediaButton.frame = NSMakeRect(520, 32, 80, 28);
    self.resetMediaButton.bezelStyle = NSBezelStyleRounded;
    [view addSubview:self.resetMediaButton];
}

- (NSString *)selectedPrintBehavior {
    return self.printBehaviorPopup.selectedItem.representedObject ?: SaveOnlyBehavior;
}

- (void)selectPrintBehavior:(NSString *)behavior {
    for (NSMenuItem *item in self.printBehaviorPopup.itemArray) {
        if ([item.representedObject isEqualToString:behavior]) {
            [self.printBehaviorPopup selectItem:item];
            return;
        }
    }
    [self.printBehaviorPopup selectItemAtIndex:0];
}

- (void)reloadForwardingPrinters {
    NSString *selected = [[NSUserDefaults standardUserDefaults] stringForKey:ForwardPrinterKey];
    [self.forwardPrinterPopup removeAllItems];
    NSArray<NSDictionary<NSString *, NSString *> *> *printers = VAPInstalledPrinters();
    for (NSDictionary<NSString *, NSString *> *printer in printers) {
        [self.forwardPrinterPopup addItemWithTitle:printer[@"displayName"]];
        self.forwardPrinterPopup.lastItem.representedObject = printer[@"name"];
    }
    if (printers.count == 0) {
        [self.forwardPrinterPopup addItemWithTitle:@"No printers installed"];
        self.forwardPrinterPopup.lastItem.representedObject = @"";
    } else {
        for (NSMenuItem *item in self.forwardPrinterPopup.itemArray) {
            if ([item.representedObject isEqualToString:selected]) {
                [self.forwardPrinterPopup selectItem:item];
                break;
            }
        }
    }
}

- (void)printBehaviorChanged:(id)sender {
    (void)sender;
    [self updateForwardingControls];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *previousBehavior = [defaults stringForKey:PrintBehaviorKey];
    NSString *selectedBehavior = [self selectedPrintBehavior];
    if (![self mediaSizesLocked]) {
        if ([selectedBehavior isEqualToString:SaveOnlyBehavior]) {
            [self restorePDFMediaSizes];
        } else {
            if ([previousBehavior isEqualToString:SaveOnlyBehavior]) {
                [self captureCurrentMediaSizesAsPDFSizes];
            }
            [self synchronizeMediaWithSelectedForwardPrinter];
        }
    }
    [defaults setObject:selectedBehavior forKey:PrintBehaviorKey];
    [defaults setObject:self.mediaSizes forKey:MediaSizesKey];
    [self applyAutomaticSettingsChange];
}

- (void)forwardPrinterChanged:(id)sender {
    (void)sender;
    if (![self mediaSizesLocked]) [self synchronizeMediaWithSelectedForwardPrinter];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:self.forwardPrinterPopup.selectedItem.representedObject ?: @""
        forKey:ForwardPrinterKey];
    [defaults setObject:self.mediaSizes forKey:MediaSizesKey];
    [self applyAutomaticSettingsChange];
}

- (void)openQueueSettingChanged:(id)sender {
    (void)sender;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:self.openQueueCheckbox.state == NSControlStateValueOn
        forKey:OpenQueueAfterForwardingKey];
    [defaults synchronize];
}

- (void)synchronizeMediaWithSelectedForwardPrinter {
    if ([self mediaSizesLocked]) return;
    NSString *printerName = self.forwardPrinterPopup.selectedItem.representedObject ?: @"";
    if (printerName.length == 0) return;
    NSString *errorMessage = nil;
    NSArray<NSDictionary<NSString *, id> *> *sizes =
        VAPSupportedMediaForPrinter(printerName, &errorMessage);
    if (sizes.count == 0) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Unable to Read Paper Sizes";
        alert.informativeText = errorMessage ?: @"The selected printer did not report any accepted paper sizes.";
        [alert beginSheetModalForWindow:self.settingsWindow completionHandler:nil];
        return;
    }
    self.mediaSizes = [self mutableMediaSizesFromArray:sizes];
    [self.mediaTable reloadData];
}

- (void)restorePDFMediaSizes {
    if (self.pdfMediaSizes.count == 0) return;
    self.mediaSizes = [self mutableMediaSizesFromArray:self.pdfMediaSizes];
    [self.mediaTable reloadData];
}

- (void)captureCurrentMediaSizesAsPDFSizes {
    self.pdfMediaSizes = [self mutableMediaSizesFromArray:self.mediaSizes];
    [[NSUserDefaults standardUserDefaults] setObject:self.pdfMediaSizes forKey:PDFMediaSizesKey];
}

- (BOOL)mediaSizesLocked {
    return [[NSUserDefaults standardUserDefaults] boolForKey:MediaSizesLockedKey];
}

- (void)toggleMediaLock:(id)sender {
    (void)sender;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL locked = ![self mediaSizesLocked];
    [defaults setBool:locked forKey:MediaSizesLockedKey];
    if (locked) {
        self.pdfMediaSizes = [self mutableMediaSizesFromArray:self.mediaSizes];
        [defaults setObject:self.pdfMediaSizes forKey:PDFMediaSizesKey];
        [defaults setObject:self.mediaSizes forKey:MediaSizesKey];
    }
    [defaults synchronize];
    [self updateMediaLockControls];
}

- (void)updateMediaLockControls {
    BOOL locked = [self mediaSizesLocked];
    self.mediaTable.enabled = !locked;
    self.mediaActions.enabled = !locked;
    self.resetMediaButton.enabled = !locked;
    NSString *symbol = locked ? @"lock.fill" : @"lock.open";
    NSString *description = locked ? @"Unlock paper sizes" : @"Lock paper sizes";
    self.mediaLockButton.image = [NSImage imageWithSystemSymbolName:symbol
        accessibilityDescription:description];
    self.mediaLockButton.toolTip = description;
}

- (void)updateForwardingControls {
    BOOL enabled = ![[self selectedPrintBehavior] isEqualToString:SaveOnlyBehavior];
    self.forwardPrinterLabel.textColor = enabled ? NSColor.labelColor : NSColor.disabledControlTextColor;
    self.forwardPrinterPopup.enabled = enabled;
    self.openQueueCheckbox.enabled = enabled;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (sender != self.settingsWindow) return YES;
    [sender makeFirstResponder:nil];
    [sender orderOut:nil];
    return NO;
}

- (void)chooseOutput:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES; panel.canChooseFiles = NO; panel.canCreateDirectories = YES;
    if ([panel runModal] == NSModalResponseOK && [self saveOutputBookmark:panel.URL]) {
        [self.activeOutputURL stopAccessingSecurityScopedResource];
        [panel.URL startAccessingSecurityScopedResource];
        self.activeOutputURL = panel.URL;
        self.outputField.stringValue = panel.URL.path;
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:OutputConfiguredKey];
        [self applyAutomaticSettingsChange];
    }
}

- (void)addMedia:(id)sender {
    if ([self mediaSizesLocked]) return;
    [self.mediaSizes addObject:[self media:@"Custom" width:210 height:297]];
    [self.mediaTable reloadData];
    [self.mediaTable selectRowIndexes:[NSIndexSet indexSetWithIndex:self.mediaSizes.count - 1] byExtendingSelection:NO];
    [self saveMediaSizesAutomatically];
}

- (void)resetMediaSizes:(id)sender {
    (void)sender;
    if ([self mediaSizesLocked]) return;
    self.mediaSizes = [self mutableMediaSizesFromArray:[self defaultMediaSizes]];
    [self.mediaTable reloadData];
    [self saveMediaSizesAutomatically];
}

- (void)changeMedia:(NSSegmentedControl *)sender {
    if (sender.selectedSegment == 0) [self addMedia:sender];
    else if (sender.selectedSegment == 1) [self removeMedia:sender];
}

- (void)removeMedia:(id)sender {
    if ([self mediaSizesLocked]) return;
    NSInteger row = self.mediaTable.selectedRow;
    if (row >= 0 && self.mediaSizes.count > 1) {
        [self.mediaSizes removeObjectAtIndex:row];
        [self.mediaTable reloadData];
        [self saveMediaSizesAutomatically];
    }
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (notification.object == self.printerNameField) {
        NSString *name = [self.printerNameField.stringValue
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length == 0) {
            self.printerNameField.stringValue = [defaults stringForKey:PrinterNameKey];
            return;
        }
        if ([name isEqualToString:[defaults stringForKey:PrinterNameKey]]) return;
        self.printerNameField.stringValue = name;
        [defaults setObject:name forKey:PrinterNameKey];
    } else if (notification.object == self.portField) {
        NSString *portText = [self.portField.stringValue
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSCharacterSet *nonDigits = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
        NSInteger port = portText.integerValue;
        BOOL valid = portText.length > 0 &&
            [portText rangeOfCharacterFromSet:nonDigits].location == NSNotFound &&
            port >= 1024 && port <= 65535;
        if (!valid) {
            self.portField.stringValue = [NSString stringWithFormat:@"%ld",
                (long)[defaults integerForKey:PrinterPortKey]];
            return;
        }
        if (port == [defaults integerForKey:PrinterPortKey]) return;
        self.portField.stringValue = [NSString stringWithFormat:@"%ld", (long)port];
        [defaults setInteger:port forKey:PrinterPortKey];
    } else {
        return;
    }
    [self applyAutomaticSettingsChange];
}

- (void)saveMediaSizesAutomatically {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:self.mediaSizes forKey:MediaSizesKey];
    if (![self mediaSizesLocked] &&
        [[self selectedPrintBehavior] isEqualToString:SaveOnlyBehavior]) {
        self.pdfMediaSizes = [self mutableMediaSizesFromArray:self.mediaSizes];
        [defaults setObject:self.pdfMediaSizes forKey:PDFMediaSizesKey];
    }
    [self applyAutomaticSettingsChange];
}

- (void)applyAutomaticSettingsChange {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults synchronize];
    if (self.printerTask.running) {
        [self stopPrinter:nil];
        [self startPrinter:nil];
    }
}

- (void)openOutputFolder:(id)sender {
    NSString *path = [[NSUserDefaults standardUserDefaults] stringForKey:OutputDirectoryKey];
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return self.mediaSizes.count; }
- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    return self.mediaSizes[row][column.identifier];
}
- (void)tableView:(NSTableView *)tableView setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    if ([self mediaSizesLocked]) { [self.mediaTable reloadData]; return; }
    if ([column.identifier isEqualToString:@"name"]) {
        NSString *name = [[value description]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length == 0) { [self.mediaTable reloadData]; return; }
        self.mediaSizes[row][@"name"] = name;
    } else {
        double dimension = [value doubleValue];
        if (dimension <= 0) { [self.mediaTable reloadData]; return; }
        self.mediaSizes[row][column.identifier] = @(dimension);
    }
    [self saveMediaSizesAutomatically];
}

@end
