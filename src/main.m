#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

static AppDelegate *appDelegate;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        (void)argc;
        (void)argv;
        NSApplication *application = NSApplication.sharedApplication;
        appDelegate = [AppDelegate new];
        application.delegate = appDelegate;
        [application run];
        return 0;
    }
}
