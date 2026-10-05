# MKB Sync

One keyboard and mouse for every Mac on your network: Universal Control for any Mac, not
just ones on your Apple ID.

MKB Sync is a small menu bar app. Install it on each Mac and put them in the same
**space**. Push the cursor off the edge of one screen and it shows up on the next Mac, with
the keyboard following along. Macs find each other automatically over Bonjour, so there are
no IP addresses to type.

## Features

- **Automatic discovery.** Macs running MKB Sync on the same network (Wi-Fi, Ethernet or
  peer-to-peer Wi-Fi) find each other with Bonjour.
- **Spaces.** Pick a space by name from the menu bar; every Mac in the same space shares one
  keyboard and mouse. Spaces seen on the network appear in the picker, or you can type a
  new name to create one. An optional passphrase keeps a space private.
- **Encrypted.** Peers talk over TLS 1.2 with a pre-shared key derived from the space name
  and passphrase. A Mac with the wrong passphrase can't complete the handshake.
- **Arrangement editor.** Drag Macs around (like System Settings ▸ Displays) to match your
  desk. The layout syncs to every Mac in the space, and multi-display Macs are supported.
- **Full input.** Mouse movement, clicks, double-clicks, drags, right and middle buttons,
  smooth trackpad and wheel scrolling, keys with modifiers and auto-repeat, and media keys
  (volume, brightness, play/pause).
- **Shared clipboard.** Text, rich text, HTML, images, PDFs and URLs copied on one Mac can
  be pasted on the others. Password-manager content marked concealed or transient is
  skipped.
- **Safe takeover.** Touching a Mac's own keyboard or mouse takes it back immediately.
  Press **⌃⌥⌘⎋** to bring the keyboard and mouse home at any time.
- **Universal Control wins.** See below.

## Living alongside Universal Control

Apple's Universal Control already handles Macs that share an iCloud account. MKB Sync stays
out of its way:

1. **No overlapping edges.** Each Mac shares, inside the encrypted session only, whether
   Universal Control is on and a salted hash of its iCloud account. Two Macs that Universal
   Control could join itself (both have it enabled, same account) form a *native pair*.
   MKB Sync never moves the cursor between them; those Macs show as "Handled by Universal
   Control". You can still use MKB Sync to reach other Macs from either of them, for
   example a work Mac on a different Apple ID.
2. **Pause while Universal Control is in use.** MKB Sync watches for input injected by the
   `UniversalControl` agent. While it is driving this Mac, or a Mac paired with this one,
   MKB Sync pauses: it hands control back if it had it, and refuses to take control until
   Universal Control goes quiet.
3. **Detection inputs.** It reads the `Disable` setting in the `com.apple.universalcontrol`
   preferences, checks that the `UniversalControl` agent process is running, and reads the
   account identifier from `MobileMeAccounts`.

Choose **Settings ▸ Universal Control ▸ Ignore Universal Control** to switch this off.

## Install

1. Download `MKBSync.zip` from the latest GitHub Actions run (artifact **MKBSync**) or from a
   release, unzip it and move **MKB Sync.app** to `/Applications`.
2. The build is ad-hoc signed, so the first time you open it, right-click the app and
   choose **Open**.
3. Grant **Accessibility** when asked (System Settings ▸ Privacy & Security ▸
   Accessibility). It is needed to capture and replay keyboard and mouse events.
4. Allow **Local Network** access when asked; discovery needs it.
5. Do the same on every other Mac, choose the same space, then use **Arrange…** to lay them
   out.

Requires macOS 13 Ventura or later. Runs on Apple silicon and Intel.

## Troubleshooting

**Keyboard or clicks stop working.** If macOS stops trusting the app while its event tap
is installed, clicks and keystrokes are dropped system-wide. MKB Sync now watches its
Accessibility permission and removes the tap within a quarter of a second if the
permission is revoked. If you are ever stuck on an older build, quit the app from another
machine (`ssh <mac> killall MKBSync`) or hold the power button to restart.

## Build from source

```sh
swift test                 # unit tests for the core logic
scripts/build-app.sh       # → dist/MKB Sync.app and dist/MKBSync.zip (universal)
ARCHS=arm64 scripts/build-app.sh                      # faster single-arch build
CODESIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
```

macOS ties Accessibility permission to the code signature. Each ad-hoc build has a new
signature, so after rebuilding you may need to remove and re-add the app in the
Accessibility list. Signing with a stable identity avoids this.

## How it works

```
Sources/
  MKBCore/                 platform-independent, unit tested
    Geometry.swift         points and rects in display coordinates
    Layout.swift           shared space layout (last-writer-wins), virtual desktop, snapping
    CursorRouter.swift     edge crossing: when the cursor leaves one Mac and enters another
    Protocol.swift         framed binary wire protocol (JSON for control, packed input events)
    Policy.swift           Universal Control policy, held-key tracking, space grouping
  MKBSync/                 the macOS app
    Discovery.swift        Bonjour advertise and browse (_mkbsync._tcp, space in TXT record)
    Transport.swift        TCP + TLS-PSK parameters
    PeerConnection.swift   framed connection per peer
    ControlEngine.swift    event tap handling, forwarding, playback, takeover
    InputCapture.swift     CGEventTap
    InputInjector.swift    CGEvent posting
    CursorController.swift hide and park the cursor while remote
    UniversalControlMonitor.swift
    ClipboardSync.swift
    AppModel.swift         sessions, layout sync, status, glue
    *View.swift            SwiftUI menu bar UI, settings, arrangement editor
```

- **Shared virtual desktop.** Each Mac's displays are placed on one plane using the space
  layout. Macs without a saved position are auto-placed left to right in a deterministic
  order, so every member agrees without coordination. Edits bump a version and win
  everywhere.
- **Routing.** The Mac whose physical mouse is moving runs the router. When its cursor is
  pinned against an outer edge and the movement continues into another Mac's display, it
  hides and freezes its own cursor (`CGAssociateMouseAndMouseCursorPosition`), swallows
  local input, and streams events with absolute positions to that Mac. Crossing further
  goes straight to the next Mac, and crossing back restores the local cursor at the
  matching point. Held keys and buttons are released on the Mac being left.
- **Connections.** Full mesh: the Mac with the smaller id dials, duplicates are resolved
  deterministically, and pings detect dead peers within about 8 seconds. All control state
  resets safely on disconnect.

## Limitations

- Trackpad gestures such as pinch, rotate and Mission Control swipes are not forwarded.
  They are swallowed while controlling another Mac.
- Universal Control detection uses public signals, not a private API. If Apple changes how
  the agent injects input, the static native-pair rule still keeps edges apart, but the
  pause-on-use signal may stop firing.
- Dragging files between Macs is not supported. Copy and paste works through the shared
  clipboard.
- While Secure Keyboard Entry is on (for example in password prompts), macOS blocks event
  taps by design.
