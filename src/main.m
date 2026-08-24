#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        /* Accessory policy = no Dock icon, no app menu bar at the top.
           The app lives entirely in the status-bar menu. */
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        /* Autoreleased: NSApplication.delegate is a weak/assign reference, so we
           balance the alloc here; the pool keeps the delegate alive for the run
           loop (the app never returns from -run under normal termination). */
        AppDelegate *delegate = [[[AppDelegate alloc] init] autorelease];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
