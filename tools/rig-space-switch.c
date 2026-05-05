// Standalone helper for instant Space switching. Built once, lives at a
// stable path, gets permission once. Rig shells out to it.
//
// Build: clang -framework ApplicationServices -framework CoreFoundation \
//        -framework CoreGraphics -O2 tools/rig-space-switch.c -o ~/.local/bin/rig-space-switch

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CGEventTypes.h>
#include <float.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Private gesture event fields.
static const CGEventField kCGSEventTypeField            = (CGEventField)55;
static const CGEventField kCGEventGestureHIDType         = (CGEventField)110;
static const CGEventField kCGEventGestureSwipeMotion     = (CGEventField)123;
static const CGEventField kCGEventGestureSwipeProgress   = (CGEventField)124;
static const CGEventField kCGEventGestureSwipeVelocityX  = (CGEventField)129;
static const CGEventField kCGEventGestureSwipeVelocityY  = (CGEventField)130;
static const CGEventField kCGEventGesturePhase           = (CGEventField)132;
static const uint32_t kIOHIDEventTypeDockSwipe = 23;

typedef int32_t CGSConnectionID;
typedef uint64_t CGSSpaceID;

extern CGSConnectionID CGSMainConnectionID(void) __attribute__((weak_import));
extern CGSSpaceID CGSGetActiveSpace(CGSConnectionID) __attribute__((weak_import));
extern CFArrayRef CGSCopyManagedDisplaySpaces(CGSConnectionID, CFStringRef) __attribute__((weak_import));

// Permission checks (macOS 10.15+).
extern bool CGPreflightPostEventAccess(void) __attribute__((weak_import));
extern bool CGRequestPostEventAccess(void) __attribute__((weak_import));

static bool post_swipe(uint8_t phase, bool right, double velocity) {
    double progress = right ? (double)FLT_TRUE_MIN : -(double)FLT_TRUE_MIN;
    double vel = right ? velocity : -velocity;
    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) return false;
    CGEventSetIntegerValueField(ev, kCGSEventTypeField, 30);
    CGEventSetIntegerValueField(ev, kCGEventGestureHIDType, kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, kCGEventGesturePhase, phase);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeProgress, progress);
    CGEventSetIntegerValueField(ev, kCGEventGestureSwipeMotion, 1);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityX, vel);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityY, vel);
    CGEventPost(kCGSessionEventTap, ev);
    CFRelease(ev);
    return true;
}

static bool switch_gesture(bool right, double velocity) {
    return post_swipe(1, right, velocity)
        && post_swipe(2, right, velocity)
        && post_swipe(4, right, velocity);
}

static bool get_current_index(unsigned int *outIndex, unsigned int *outCount) {
    if (&CGSMainConnectionID == NULL || &CGSGetActiveSpace == NULL || &CGSCopyManagedDisplaySpaces == NULL)
        return false;
    CGSConnectionID cid = CGSMainConnectionID();
    CGSSpaceID active = CGSGetActiveSpace(cid);
    if (active == 0) return false;

    CGEventRef tmp = CGEventCreate(NULL);
    CGPoint cursor = CGEventGetLocation(tmp);
    CFRelease(tmp);
    CFStringRef displayID = NULL;
    CGDirectDisplayID disp = 0;
    uint32_t dc = 0;
    if (CGGetDisplaysWithPoint(cursor, 1, &disp, &dc) == kCGErrorSuccess && dc > 0) {
        CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(disp);
        if (uuid) { displayID = CFUUIDCreateString(NULL, uuid); CFRelease(uuid); }
    }
    CFArrayRef displays = CGSCopyManagedDisplaySpaces(cid, displayID);
    if (!displays && displayID) displays = CGSCopyManagedDisplaySpaces(cid, NULL);
    if (displayID) CFRelease(displayID);
    if (!displays) return false;

    bool found = false;
    for (CFIndex di = 0; di < CFArrayGetCount(displays) && !found; di++) {
        CFDictionaryRef dd = CFArrayGetValueAtIndex(displays, di);
        CFDictionaryRef curSpace = CFDictionaryGetValue(dd, CFSTR("Current Space"));
        CGSSpaceID displayActive = 0;
        if (curSpace) {
            CFNumberRef sid = CFDictionaryGetValue(curSpace, CFSTR("id64"));
            if (sid) CFNumberGetValue(sid, kCFNumberSInt64Type, &displayActive);
        }
        CGSSpaceID target = displayActive ? displayActive : active;
        CFArrayRef spaces = CFDictionaryGetValue(dd, CFSTR("Spaces"));
        if (!spaces) continue;
        unsigned int idx = 0;
        for (CFIndex si = 0; si < CFArrayGetCount(spaces); si++) {
            CFDictionaryRef sd = CFArrayGetValueAtIndex(spaces, si);
            CFNumberRef idNum = CFDictionaryGetValue(sd, CFSTR("id64"));
            if (!idNum) continue;
            CGSSpaceID candidate = 0;
            CFNumberGetValue(idNum, kCFNumberSInt64Type, &candidate);
            if (candidate == target) { *outIndex = idx; found = true; break; }
            idx++;
        }
        if (found) *outCount = (unsigned int)CFArrayGetCount(spaces);
    }
    CFRelease(displays);
    return found;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: rig-space-switch <index>\n");
        return 2;
    }

    // Permission check — the whole reason this helper exists.
    if (&CGPreflightPostEventAccess != NULL) {
        bool has = CGPreflightPostEventAccess();
        fprintf(stderr, "PostEventAccess: %s\n", has ? "YES" : "NO");
        if (!has) {
            fprintf(stderr, "ERR:no-permission\n");
            if (&CGRequestPostEventAccess != NULL) {
                CGRequestPostEventAccess();
            }
            // Also check Accessibility — some macOS versions conflate the two.
            fprintf(stderr, "AXIsProcessTrusted: %s\n",
                    AXIsProcessTrusted() ? "YES" : "NO");
            return 3;
        }
    }

    unsigned int targetIndex = (unsigned int)atoi(argv[1]);
    unsigned int curIndex = 0, count = 0;
    if (!get_current_index(&curIndex, &count)) {
        fprintf(stderr, "ERR:no-space-info\n");
        return 1;
    }
    fprintf(stderr, "current=%u target=%u count=%u\n", curIndex, targetIndex, count);

    if (targetIndex >= count) targetIndex = count - 1;
    if (curIndex == targetIndex) { printf("OK:already\n"); return 0; }

    bool right = targetIndex > curIndex;
    unsigned int steps = right ? (targetIndex - curIndex) : (curIndex - targetIndex);
    double velocity = 2000.0 * steps;
    for (unsigned int i = 0; i < steps; i++) {
        if (!switch_gesture(right, velocity)) {
            fprintf(stderr, "ERR:gesture-failed\n");
            return 1;
        }
    }

    // Wait for the Space to actually change (up to 500ms).
    for (int attempt = 0; attempt < 10; attempt++) {
        usleep(50000); // 50ms
        unsigned int nowIndex = 0, nowCount = 0;
        if (get_current_index(&nowIndex, &nowCount) && nowIndex == targetIndex) {
            printf("OK:switched\n");
            return 0;
        }
    }

    fprintf(stderr, "WARN:switch-posted-but-space-unchanged\n");
    printf("OK:posted\n");
    return 0;
}
