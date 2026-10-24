Audio IO Keeper
===============

A tiny native macOS menu-bar app that keeps your chosen audio input and
output devices exactly where you put them.

macOS loves to switch audio devices on its own: take out an AirPod, walk
near your iPhone, plug in a display — and your mic or speakers silently
change mid-call. Audio IO Keeper pins the devices you choose and, whenever
macOS moves a default on its own, moves it straight back.

Install
-------
1. Drag "AudioIOKeeper" onto the Applications shortcut in this disk image.
2. Open it from Applications. It lives in your menu bar (waveform icon) —
   there is no Dock icon or main window.
3. First launch only: this build is not notarized by Apple, so if macOS
   warns that it cannot check the app, right-click (Control-click) the app
   in Applications, choose Open, then confirm Open. You only do this once.

Using it
--------
- Click the waveform icon in the menu bar.
- Pick the output and input devices you want to keep. Picking a device pins
  it and makes it the system default immediately. "Keep" can be switched
  off per direction.
- On first launch the app adopts whatever macOS is already using as the
  initial pins, so "keep what I have" works right away.
- If a pinned device disconnects, nothing breaks: macOS uses its fallback
  and your pin is restored the moment the device returns.
- If another app or automation keeps switching a device back, Audio IO
  Keeper backs off gradually and shows the conflict in the popover rather
  than fighting it switch-for-switch.
- Every action is shown in the popover's activity log.
- Settings… (in the popover) has "Launch at login". About… shows version
  and safety details. "Quit Audio IO Keeper" stops keeping immediately.

Safety
------
Audio IO Keeper only reads and writes the standard system-default
input/output device — the exact same Core Audio settings that
System Settings → Sound uses. No drivers, kernel/system extensions, or
audio plug-ins; no private APIs; it never records or plays audio; no
network code. It runs in the App Sandbox with the Hardened Runtime.

Uninstall
---------
Quit the app from its menu, then delete it from Applications. Nothing else
is left behind on your system.

Requirements
------------
macOS 14 (Sonoma) or later.

Source & license
----------------
https://github.com/neuroccm/AudioIOKeeper — MIT License (see LICENSE).
Copyright © 2026 Audio IO Keeper contributors.
