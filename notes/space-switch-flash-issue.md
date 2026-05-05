**The problem:**

When the user clicks a session in Rig to switch to a different full-screen Ghostty window, the switch works (instant, no slow animation), but for a split second the Ghostty window visibly flashes above Rig's sidebar panel before settling behind it. It's a brief z-order flicker — maybe one or two frames — but it's noticeable and makes the transition feel unpolished.

**The user's setup:**

- Every Ghostty session runs in its own macOS full-screen Space
- Rig is a floating NSPanel with `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.stationary` collection behavior
- Rig uses synthetic Dock-swipe gesture events (ported from InstantSpaceSwitcher) to instantly switch between full-screen Spaces when the user clicks a session

**What happens during a switch:**

1. User clicks a session row in Rig
2. Rig posts synthetic gesture events to instantly switch to the target Space
3. Rig calls AppleScript `focus` on the Ghostty terminal to bring it forward
4. During step 2→3, the Ghostty window briefly renders above Rig's panel for ~1 frame before the compositor re-asserts Rig's window level

**What we've tried:**

1. **Panel level `.floating` (3)** — the default. Ghostty flashes above it during Space transitions.

2. **Temporarily raising panel to `.popUpMenu` (101) before the switch, restoring after** — didn't reliably prevent the flash. The restore timing was tricky: too early = flash still happens; too late = panel covers menus.

3. **Permanently setting panel to `.modalPanel` (8)** — current state. Still flashes. The Space transition animation appears to temporarily bring the incoming full-screen window above even `.modalPanel` level during the compositor's transition.

**The core issue:**

During a macOS Space transition (even an instant one via synthetic gestures), the compositor briefly renders the incoming Space's windows at a level that's above our panel. This seems to be baked into how macOS composites Space transitions — the incoming full-screen window gets special treatment during the animation, regardless of our panel's static level. Setting the panel to higher levels (`.popUpMenu` at 101, `.screenSaver` at 1000) hasn't been tested yet but may not help if the compositor treats full-screen Space transitions specially.

**What hasn't been tried:**

- `.screenSaver` level (1000) — the highest non-system level
- Using `CGSSetWindowLevel` (private API) to set a custom level even higher
- Posting the synthetic gesture with a delay between Rig's panel being ordered front and the actual Space switch
- Having the panel momentarily `orderOut` during the transition and `orderFront` after (hide Rig entirely for the ~50ms transition so the user never sees a z-order conflict)
- Investigating whether the flash is specifically a full-screen-Space compositor behavior that no window level can override