#import <Foundation/Foundation.h>
#import <assert.h>
#import "MacVNCPermissionUI.h"

static void expectContains(NSString *haystack, NSString *needle, const char *what)
{
    if ([haystack rangeOfString:needle].location == NSNotFound) {
        fprintf(stderr, "FAIL %s: %s\n  missing: %s\n",
                what, haystack.UTF8String, needle.UTF8String);
        abort();
    }
}

static void expectExcludes(NSString *haystack, NSString *needle, const char *what)
{
    if ([haystack rangeOfString:needle].location != NSNotFound) {
        fprintf(stderr, "FAIL %s: %s\n  must not contain: %s\n",
                what, haystack.UTF8String, needle.UTF8String);
        abort();
    }
}

static MacVNCPermissionUIInput makeInput(BOOL screen, BOOL ax, BOOL running)
{
    MacVNCPermissionUIInput in;
    in.screenActive        = screen;
    in.accessibilityActive = ax;
    in.serverRunning       = running;
    in.inApplicationsFolder = YES;   /* the normal, installed case */
    return in;
}

int main(void)
{
    @autoreleasepool {
        /* ---- S1: neither permission active ---- */
        MacVNCPermissionUIState *s1 =
            macVNCResolvePermissionUI(makeInput(NO, NO, NO));
        assert(s1.shouldShowPanel);
        expectContains(s1.screenChipTitle, @"⚠", "S1 screen chip warns");
        expectContains(s1.accessibilityChipTitle, @"⚠", "S1 ax chip warns");
        /* Observed bug: the first screen after a reset never mentioned "+",
           leaving the user at a Settings list with no macVNC row. */
        expectContains(s1.hint, @"press +", "S1 hint explains the + step");
        expectContains(s1.hint, @"Run macVNC", "S1 hint names the action");

        /* ---- S2: only Accessibility active ---- */
        MacVNCPermissionUIState *s2 =
            macVNCResolvePermissionUI(makeInput(NO, YES, NO));
        assert(s2.shouldShowPanel);
        expectContains(s2.accessibilityChipTitle, @"✓", "S2 ax chip ok");
        expectContains(s2.hint, @"Screen Recording", "S2 hint names the missing one");
        expectContains(s2.hint, @"press +", "S2 hint explains the + step");

        /* ---- S3: only Screen Recording active ---- */
        MacVNCPermissionUIState *s3 =
            macVNCResolvePermissionUI(makeInput(YES, NO, NO));
        assert(s3.shouldShowPanel);
        expectContains(s3.screenChipTitle, @"✓", "S3 screen chip ok");
        expectContains(s3.hint, @"Accessibility", "S3 hint names the missing one");

        /* ---- S4: both active ---- */
        MacVNCPermissionUIState *s4 =
            macVNCResolvePermissionUI(makeInput(YES, YES, NO));
        expectContains(s4.screenChipTitle, @"✓", "S4 screen chip ok");
        expectContains(s4.accessibilityChipTitle, @"✓", "S4 ax chip ok");
        assert(!s4.shouldShowPanel);           /* nothing to ask for */
        assert(!s4.buttonRelaunches);          /* just start, no relaunch */

        /* ---- S0: server running -> gate must stay hidden ---- */
        MacVNCPermissionUIState *s0 =
            macVNCResolvePermissionUI(makeInput(NO, NO, YES));
        assert(!s0.shouldShowPanel);

        /* ---- I1: chips and hint may never contradict each other ----
           The original bug: chip "Restart required" + hint "All permissions
           granted", because each was computed from its own TCC sample. */
        for (int screen = 0; screen <= 1; screen++) {
            for (int ax = 0; ax <= 1; ax++) {
                MacVNCPermissionUIState *st =
                    macVNCResolvePermissionUI(makeInput(screen, ax, NO));
                BOOL claimsAllGood =
                    [st.hint rangeOfString:@"Both permissions are active"].location != NSNotFound;
                assert(claimsAllGood == (screen && ax));

                /* I5: no dead ends anywhere. */
                assert(st.buttonEnabled);
                assert([st.buttonTitle isEqualToString:@"Run macVNC"]);

                /* I2: "restart required" is never presented as a measured fact;
                   the platform gives no way to tell it from "not granted". */
                expectExcludes(st.screenChipTitle, @"Restart required", "no restart claim");
                expectExcludes(st.accessibilityChipTitle, @"Restart required", "no restart claim");

                /* An inactive permission must always offer the applying step,
                   because it may already be enabled in System Settings and only
                   be invisible to this process. */
                if (!screen || !ax)
                    expectContains(st.hint, @"Run macVNC", "inactive state offers the fix");
            }
        }

        /* ---- Wording must not accuse the user of not granting it ----
           macOS binds both permissions at launch, so "Not granted" was wrong:
           the user may have granted it a second ago. */
        MacVNCPermissionUIState *wording =
            macVNCResolvePermissionUI(makeInput(NO, NO, NO));
        expectExcludes(wording.screenChipTitle, @"Not granted", "chip avoids 'Not granted'");
        expectContains(wording.screenChipTitle, @"Not active yet", "chip says 'Not active yet'");
        /* macVNC never raises macOS's own permission dialog, so the Screen
           Recording row is never created for the user: the "+" steps are the
           only way in and must always be spelled out. */
        expectContains(wording.hint, @"press +", "hint spells out the + step");
        expectContains(wording.hint, @"Applications", "hint says where to find macVNC");
        /* And the restart must always be named, because a granted permission is
           invisible to the already-running process. */
        expectContains(wording.hint, @"freshly started",
                       "hint explains why a restart is needed");

        /* Running from outside /Applications: the "+" instruction would send the
           user to a different copy of the app, so it must say so first. */
        MacVNCPermissionUIInput elsewhere = makeInput(NO, NO, NO);
        elsewhere.inApplicationsFolder = NO;
        MacVNCPermissionUIState *misplaced = macVNCResolvePermissionUI(elsewhere);
        expectContains(misplaced.hint, @"Applications folder",
                       "warns when not installed in Applications");
        expectExcludes(misplaced.hint, @"pick macVNC in Applications",
                       "does not give the plain + steps from the wrong location");

        /* Rows and the status line above them must be driven by ONE decision:
           they were derived separately, so the line could claim "permissions
           required" while the rows were hidden. */
        for (int screen = 0; screen <= 1; screen++) {
            for (int ax = 0; ax <= 1; ax++) {
                MacVNCPermissionUIState *st =
                    macVNCResolvePermissionUI(makeInput(screen, ax, NO));
                assert(st.shouldShowPermissionRows == !(screen && ax));
                /* Panel and rows may differ only by "is the server running". */
                assert(st.shouldShowPanel == st.shouldShowPermissionRows);
            }
        }
        MacVNCPermissionUIState *running =
            macVNCResolvePermissionUI(makeInput(NO, NO, YES));
        assert(!running.shouldShowPanel);            /* never over a live server */
        assert(running.shouldShowPermissionRows);    /* but the menu still warns */

        /* The instruction text is the ONLY route to granting Screen Recording,
           and it was once silently truncated by a fixed-height label. Assert the
           budget the panel layout is built for (432pt wide x 112pt tall at the
           small system font ~ 4 lines): if the copy outgrows it, fail here
           rather than clipping it on screen. */
        for (int screen = 0; screen <= 1; screen++) {
            for (int ax = 0; ax <= 1; ax++) {
                MacVNCPermissionUIState *st =
                    macVNCResolvePermissionUI(makeInput(screen, ax, NO));
                if (st.hint.length > 420) {
                    fprintf(stderr,
                            "FAIL hint too long for the panel label: %lu chars\n"
                            "  %s\n",
                            (unsigned long)st.hint.length, st.hint.UTF8String);
                    abort();
                }
            }
        }

        /* shouldStartServer is not merely !shouldShowPanel: with the server
           already running both must be NO, or the gate would restart it. */
        for (int screen = 0; screen <= 1; screen++) {
            for (int ax = 0; ax <= 1; ax++) {
                for (int run = 0; run <= 1; run++) {
                    MacVNCPermissionUIState *st =
                        macVNCResolvePermissionUI(makeInput(screen, ax, run));
                    assert(st.shouldStartServer == (screen && ax && !run));
                    assert(!(st.shouldStartServer && st.shouldShowPanel));
                }
            }
        }

        printf("test_permission_ui: all assertions passed\n");
    }
    return 0;
}
