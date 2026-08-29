#pragma once

#import <Foundation/Foundation.h>

#import "MacVNCCurtainInput.h"   /* MacVNCCurtainInputTap */

/*
 * THE DEVICE HALF OF CURTAIN MODE, AND NOTHING ELSE.
 *
 * MacVNCCurtainInput owns the DECISIONS - the three preconditions, the
 * pass-through of our own injection, both disable reasons, the secure-input
 * transition, the focus latch, the watchdog's verdicts - and every one of them
 * is a pure function or a call over a seam, tested in tests/test_curtain_input.m
 * with real CGEvents and no device. This class is the seam's other side: a real
 * CGEventTap, on its own thread, with a run loop, a poll timer, a watchdog
 * thread and an abort().
 *
 * The split is not cosmetic. MacVNCCurtainInput.h's closing block lists what is
 * only ARGUED rather than tested, and every item on it lives here:
 *
 *   - the monotone refusal latch (_refuseForever): a tap whose teardown never
 *     joined must never arm again, and the tap thread must not be able to clear
 *     that by finishing late;
 *   - publishing setup success only while nobody has given up on it, and
 *     answering "already started" only while a run loop is still live;
 *   - the handler being retained for both the tap and the WATCHDOG thread, and
 *     released only when BOTH joins succeed (leaked otherwise);
 *   - the semaphore lifetimes on every timeout branch;
 *   - the watchdog's own start handshake, and the rule that a watchdog which
 *     does not start is a start FAILURE rather than a degraded success;
 *   - the resume grace window, and abort() itself, which by construction cannot
 *     be observed by a test that must survive it.
 *
 * So this header exists to make that surface one file a reviewer can point at,
 * and to give a future device test - the only kind that could cover the list
 * above - a way in. Nothing else imports it: the production wiring
 * (+inputWithDefaultSeamsFocus:) is implemented in MacVNCCurtainEventTap.m for
 * the same reason, so a target that wants the decisions links no tap at all.
 *
 * THREADING: -startWithEventMask:handler: and -stop are called on the MAIN
 * thread; everything they deliver arrives on the tap's own thread.
 */
@interface MacVNCCurtainEventTap : NSObject <MacVNCCurtainInputTap>
@end
