// Adapted from InstantSpaceSwitcher (MIT License).
// Copyright (c) InstantSpaceSwitcher contributors.
//
// Core Spaces-switching engine for Rig. Posts synthetic Dock-swipe gesture
// events with high velocity so the Space transition is effectively instant.
// Also reads Space state via private CGS APIs and maps CGWindowIDs to their
// Space index.

#include "SpaceSwitching.h"

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CGEventTypes.h>
#include <dlfcn.h>
#include <float.h>
#include <stdio.h>
#include <string.h>

// Private gesture event fields (empirical, stable since ~10.10).
static const CGEventField kCGSEventTypeField            = (CGEventField)55;
static const CGEventField kCGEventGestureHIDType         = (CGEventField)110;
static const CGEventField kCGEventGestureSwipeMotion     = (CGEventField)123;
static const CGEventField kCGEventGestureSwipeProgress   = (CGEventField)124;
static const CGEventField kCGEventGestureSwipeVelocityX  = (CGEventField)129;
static const CGEventField kCGEventGestureSwipeVelocityY  = (CGEventField)130;
static const CGEventField kCGEventGesturePhase           = (CGEventField)132;

static const uint32_t kIOHIDEventTypeDockSwipe = 23;

typedef uint32_t CGSEventType;
enum {
    kCGSEventDockControl = 30,
};

typedef CF_ENUM(uint8_t, CGSGesturePhase) {
    kCGSGesturePhaseBegan   = 1,
    kCGSGesturePhaseChanged = 2,
    kCGSGesturePhaseEnded   = 4,
};

typedef CF_ENUM(uint16_t, CGGestureMotion) {
    kCGGestureMotionHorizontal = 1,
};

typedef int32_t CGSConnectionID;
typedef uint64_t CGSSpaceID;

// Private CGS symbols (weak-imported so we fail gracefully if missing).
extern CGSConnectionID CGSMainConnectionID(void)                                           __attribute__((weak_import));
extern CGSSpaceID      CGSGetActiveSpace(CGSConnectionID)                                  __attribute__((weak_import));
extern CFArrayRef      CGSCopyManagedDisplaySpaces(CGSConnectionID, CFStringRef)            __attribute__((weak_import));
extern CFStringRef     CGSCopyActiveMenuBarDisplayIdentifier(CGSConnectionID)               __attribute__((weak_import));
extern CFArrayRef      CGSCopySpacesForWindows(CGSConnectionID, int, CFArrayRef)            __attribute__((weak_import));

// Internal state.
static CFMutableDictionaryRef predictionsDict = NULL;
static double gestureSpeed = 2000.0;

// MARK: - Predictions

static bool get_prediction(const char *displayID, unsigned int *outIndex) {
    if (!displayID || !predictionsDict) return false;
    CFStringRef key = CFStringCreateWithCString(NULL, displayID, kCFStringEncodingUTF8);
    const void *value = CFDictionaryGetValue(predictionsDict, key);
    CFRelease(key);
    if (value) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, outIndex);
        return true;
    }
    return false;
}

static void set_prediction(const char *displayID, unsigned int index) {
    if (!displayID || !predictionsDict) return;
    CFStringRef key = CFStringCreateWithCString(NULL, displayID, kCFStringEncodingUTF8);
    CFNumberRef val = CFNumberCreate(NULL, kCFNumberIntType, &index);
    CFDictionarySetValue(predictionsDict, key, val);
    CFRelease(key);
    CFRelease(val);
}

void rig_space_reset_predictions(void) {
    if (predictionsDict) {
        CFDictionaryRemoveAllValues(predictionsDict);
    }
}

// MARK: - CGS availability

static bool cgs_symbols_available(void) {
    return (&CGSMainConnectionID != NULL) &&
           (&CGSGetActiveSpace != NULL) &&
           (&CGSCopyManagedDisplaySpaces != NULL);
}

// MARK: - Space info

static bool extract_space_info(CFDictionaryRef displayDict,
                               CGSSpaceID activeSpace,
                               bool hasActiveSpace,
                               RigSpaceInfo *outInfo) {
    if (!displayDict || !outInfo) return false;

    memset(outInfo->displayID, 0, sizeof(outInfo->displayID));
    CFStringRef identifier = CFDictionaryGetValue(displayDict, CFSTR("Display Identifier"));
    if (identifier && CFGetTypeID(identifier) == CFStringGetTypeID()) {
        CFStringGetCString(identifier, outInfo->displayID, sizeof(outInfo->displayID), kCFStringEncodingUTF8);
    }

    const void *spacesValue = CFDictionaryGetValue(displayDict, CFSTR("Spaces"));
    if (!spacesValue || CFGetTypeID(spacesValue) != CFArrayGetTypeID()) return false;

    CGSSpaceID displayActiveSpace = 0;
    const void *currentSpaceValue = CFDictionaryGetValue(displayDict, CFSTR("Current Space"));
    if (currentSpaceValue && CFGetTypeID(currentSpaceValue) == CFDictionaryGetTypeID()) {
        CFNumberRef sid = CFDictionaryGetValue(currentSpaceValue, CFSTR("id64"));
        if (sid && CFGetTypeID(sid) == CFNumberGetTypeID()) {
            CFNumberGetValue(sid, kCFNumberSInt64Type, &displayActiveSpace);
        }
    }

    CGSSpaceID target = displayActiveSpace != 0 ? displayActiveSpace : activeSpace;
    bool hasTarget = displayActiveSpace != 0 || hasActiveSpace;

    CFArrayRef spaces = (CFArrayRef)spacesValue;
    CFIndex count = CFArrayGetCount(spaces);
    unsigned int total = 0, activeIdx = 0;
    bool found = false;

    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef sd = (CFDictionaryRef)CFArrayGetValueAtIndex(spaces, i);
        if (!sd || CFGetTypeID(sd) != CFDictionaryGetTypeID()) continue;
        CFNumberRef idNum = CFDictionaryGetValue(sd, CFSTR("id64"));
        if (!idNum || CFGetTypeID(idNum) != CFNumberGetTypeID()) continue;
        CGSSpaceID candidate = 0;
        if (CFNumberGetValue(idNum, kCFNumberSInt64Type, &candidate)) {
            if (!found && hasTarget && candidate == target) {
                activeIdx = total;
                found = true;
            }
            total++;
        }
    }

    if (total == 0 || (hasTarget && !found)) return false;
    outInfo->spaceCount = total;
    outInfo->currentIndex = found ? activeIdx : 0;
    return true;
}

static bool load_space_info(RigSpaceInfo *info) {
    if (!cgs_symbols_available()) return false;

    CGSConnectionID cid = CGSMainConnectionID();
    if (cid == 0) return false;

    CGSSpaceID activeSpace = 0;
    bool hasActive = false;
    if (&CGSGetActiveSpace != NULL) {
        activeSpace = CGSGetActiveSpace(cid);
        if (activeSpace == 0) return false;
        hasActive = true;
    }

    // Use cursor display.
    CFStringRef displayIdent = NULL;
    CGEventRef tempEv = CGEventCreate(NULL);
    CGPoint cursor = CGEventGetLocation(tempEv);
    CFRelease(tempEv);
    CGDirectDisplayID cursorDisp = 0;
    uint32_t dispCount = 0;
    if (CGGetDisplaysWithPoint(cursor, 1, &cursorDisp, &dispCount) == kCGErrorSuccess && dispCount > 0) {
        CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(cursorDisp);
        if (uuid) {
            displayIdent = CFUUIDCreateString(NULL, uuid);
            CFRelease(uuid);
        }
    }

    CFArrayRef displays = CGSCopyManagedDisplaySpaces(cid, displayIdent);
    if (!displays && displayIdent) {
        displays = CGSCopyManagedDisplaySpaces(cid, NULL);
    }
    if (!displays) {
        if (displayIdent) CFRelease(displayIdent);
        return false;
    }

    CFIndex dCount = CFArrayGetCount(displays);
    CFDictionaryRef targetDisp = NULL;
    CFDictionaryRef fallback = NULL;

    for (CFIndex i = 0; i < dCount; i++) {
        CFDictionaryRef dd = (CFDictionaryRef)CFArrayGetValueAtIndex(displays, i);
        if (!dd || CFGetTypeID(dd) != CFDictionaryGetTypeID()) continue;
        if (!fallback) fallback = dd;
        if (!displayIdent || targetDisp) continue;
        CFStringRef ident = CFDictionaryGetValue(dd, CFSTR("Display Identifier"));
        if (ident && CFEqual(ident, displayIdent)) targetDisp = dd;
    }

    if (!targetDisp) targetDisp = fallback;
    bool ok = targetDisp ? extract_space_info(targetDisp, activeSpace, hasActive, info) : false;
    if (displayIdent) CFRelease(displayIdent);
    CFRelease(displays);
    return ok;
}

// MARK: - Synthetic gesture

static bool post_dock_swipe(CGSGesturePhase phase, bool right, double velocity) {
    double progress = right ? (double)FLT_TRUE_MIN : -(double)FLT_TRUE_MIN;
    double vel = right ? velocity : -velocity;

    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) return false;
    CGEventSetIntegerValueField(ev, kCGSEventTypeField, kCGSEventDockControl);
    CGEventSetIntegerValueField(ev, kCGEventGestureHIDType, kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, kCGEventGesturePhase, phase);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeProgress, progress);
    CGEventSetIntegerValueField(ev, kCGEventGestureSwipeMotion, kCGGestureMotionHorizontal);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityX, vel);
    CGEventSetDoubleValueField(ev, kCGEventGestureSwipeVelocityY, vel);
    CGEventPost(kCGSessionEventTap, ev);
    CFRelease(ev);
    return true;
}

static bool perform_switch_gesture(bool right, double velocity) {
    return post_dock_swipe(kCGSGesturePhaseBegan,   right, velocity)
        && post_dock_swipe(kCGSGesturePhaseChanged, right, velocity)
        && post_dock_swipe(kCGSGesturePhaseEnded,   right, velocity);
}

// MARK: - Bounds check

static bool should_block(const RigSpaceInfo *info, bool right) {
    if (!info || info->spaceCount == 0) return true;
    unsigned int predicted;
    unsigned int cur = get_prediction(info->displayID, &predicted) ? predicted : info->currentIndex;
    return right ? (cur + 1 >= info->spaceCount) : (cur == 0);
}

// MARK: - Window → Space mapping

int rig_space_index_for_window(CGWindowID windowID) {
    if (!cgs_symbols_available() || &CGSCopySpacesForWindows == NULL) {
        fprintf(stderr, "[RIG-SPACE] index_for_window: CGS symbols missing\n");
        return -1;
    }

    CGSConnectionID cid = CGSMainConnectionID();
    if (cid == 0) return -1;

    // Get Spaces for this window.
    CFNumberRef wid = CFNumberCreate(NULL, kCFNumberSInt32Type, &windowID);
    CFArrayRef widArr = CFArrayCreate(NULL, (const void *[]){wid}, 1, &kCFTypeArrayCallBacks);
    // Mask 0x7 = all space types (user, fullscreen, system).
    CFArrayRef spaceIDs = CGSCopySpacesForWindows(cid, 0x7, widArr);
    CFRelease(widArr);
    CFRelease(wid);

    if (!spaceIDs || CFArrayGetCount(spaceIDs) == 0) {
        if (spaceIDs) CFRelease(spaceIDs);
        return -1;
    }

    CGSSpaceID windowSpace = 0;
    CFNumberRef firstSpace = CFArrayGetValueAtIndex(spaceIDs, 0);
    CFNumberGetValue(firstSpace, kCFNumberSInt64Type, &windowSpace);
    CFRelease(spaceIDs);

    if (windowSpace == 0) return -1;

    // Walk all Spaces to find its index.
    CFArrayRef displays = CGSCopyManagedDisplaySpaces(cid, NULL);
    if (!displays) return -1;

    int result = -1;
    CFIndex dCount = CFArrayGetCount(displays);
    for (CFIndex di = 0; di < dCount && result < 0; di++) {
        CFDictionaryRef dd = (CFDictionaryRef)CFArrayGetValueAtIndex(displays, di);
        if (!dd || CFGetTypeID(dd) != CFDictionaryGetTypeID()) continue;
        CFArrayRef spaces = CFDictionaryGetValue(dd, CFSTR("Spaces"));
        if (!spaces || CFGetTypeID(spaces) != CFArrayGetTypeID()) continue;
        unsigned int idx = 0;
        for (CFIndex si = 0; si < CFArrayGetCount(spaces); si++) {
            CFDictionaryRef sd = (CFDictionaryRef)CFArrayGetValueAtIndex(spaces, si);
            if (!sd || CFGetTypeID(sd) != CFDictionaryGetTypeID()) continue;
            CFNumberRef idNum = CFDictionaryGetValue(sd, CFSTR("id64"));
            if (!idNum) continue;
            CGSSpaceID candidate = 0;
            CFNumberGetValue(idNum, kCFNumberSInt64Type, &candidate);
            if (candidate == windowSpace) {
                result = (int)idx;
                break;
            }
            idx++;
        }
    }
    CFRelease(displays);
    return result;
}

// MARK: - Public API

bool rig_space_init(void) {
    if (!predictionsDict) {
        predictionsDict = CFDictionaryCreateMutable(
            NULL, 0,
            &kCFCopyStringDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks
        );
    }
    return cgs_symbols_available();
}

void rig_space_destroy(void) {
    if (predictionsDict) {
        CFRelease(predictionsDict);
        predictionsDict = NULL;
    }
}

bool rig_space_get_info(RigSpaceInfo *info) {
    if (!info) return false;
    memset(info, 0, sizeof(*info));
    return load_space_info(info);
}

bool rig_space_switch_to_index(unsigned int targetIndex) {
    RigSpaceInfo info;
    if (!rig_space_get_info(&info)) {
        fprintf(stderr, "[RIG-SPACE] get_info failed\n");
        return false;
    }
    if (info.spaceCount == 0) {
        fprintf(stderr, "[RIG-SPACE] spaceCount is 0\n");
        return false;
    }

    if (targetIndex >= info.spaceCount) {
        targetIndex = info.spaceCount - 1;
    }

    unsigned int predicted;
    unsigned int cur = get_prediction(info.displayID, &predicted) ? predicted : info.currentIndex;
    if (cur == targetIndex) {
        fprintf(stderr, "[RIG-SPACE] already on target space %u\n", targetIndex);
        return true;
    }

    bool right = targetIndex > cur;
    unsigned int steps = right ? (targetIndex - cur) : (cur - targetIndex);
    double velocity = gestureSpeed * steps;

    fprintf(stderr, "[RIG-SPACE] switching from %u to %u (%u steps, %s, vel=%.0f)\n",
            cur, targetIndex, steps, right ? "right" : "left", velocity);

    for (unsigned int i = 0; i < steps; i++) {
        if (!perform_switch_gesture(right, velocity)) {
            fprintf(stderr, "[RIG-SPACE] gesture post FAILED at step %u\n", i);
            return false;
        }
    }

    fprintf(stderr, "[RIG-SPACE] switch posted OK\n");
    set_prediction(info.displayID, targetIndex);
    return true;
}

void rig_space_set_speed(double speed) {
    gestureSpeed = speed;
}
