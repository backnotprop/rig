// Adapted from InstantSpaceSwitcher (MIT License).
// Copyright (c) InstantSpaceSwitcher contributors.
//
// Stripped to the subset Rig needs: read Space info, switch to a Space index,
// and map a CGWindowID to its Space index. No event tap, no swipe override,
// no overlay detection.

#ifndef _SPACESWITCHING_H
#define _SPACESWITCHING_H

#include <stdbool.h>
#include <stdint.h>
#include <CoreGraphics/CoreGraphics.h>

typedef struct {
    unsigned int currentIndex;
    unsigned int spaceCount;
    char displayID[128];
} RigSpaceInfo;

/// Initialize internal state. Call once at app startup. Returns true on success.
bool rig_space_init(void);

/// Clean up.
void rig_space_destroy(void);

/// Get the current Space info for the display where the cursor lives.
bool rig_space_get_info(RigSpaceInfo *info);

/// Instantly switch to the Space at `targetIndex` (zero-based).
/// Returns true if the switch was posted (or already on target).
bool rig_space_switch_to_index(unsigned int targetIndex);

/// Returns the zero-based Space index that `windowID` lives on, or -1 if the
/// window can't be found on any Space. Uses private CGS APIs.
int rig_space_index_for_window(CGWindowID windowID);

/// Set the velocity used for synthetic gestures. Default is 2000.
void rig_space_set_speed(double speed);

/// Reset predicted indices. Call from activeSpaceDidChangeNotification.
void rig_space_reset_predictions(void);

#endif
