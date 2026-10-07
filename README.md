# CapsTalk

A native macOS menu bar app for Caps Lock push-to-talk. Requires macOS 13 or later.

- Hold **Caps Lock** to unmute the default system microphone.
- Release **Caps Lock** to mute it.
- Caps Lock no longer toggles capitalization while CapsTalk is enabled.
- The menu bar icon shows a crossed-out microphone while muted and a green microphone while talking.
- Pause or quit from the menu to restore your original microphone settings and Caps Lock mapping.

## Install

1. [Download CapsTalk for macOS](https://github.com/GuiSim/caps-talk/releases/latest/download/CapsTalk-1.1.0-universal.dmg).
2. Open the DMG and drag **CapsTalk** onto **Applications**.
3. Open **CapsTalk** from Applications. Its microphone icon appears in the menu bar.
4. Enable **CapsTalk** in **System Settings → Privacy & Security → Accessibility** when prompted.

The download works on Apple silicon and Intel Macs running macOS 13 or later. No Terminal commands or developer tools are needed. A **Start Here.pdf** guide is included in the installer.

**First release:** the app has not been notarized by Apple. If macOS blocks it, after attempting to open it go to **System Settings → Privacy & Security → Open Anyway**, then confirm **Open**. Only do this for the official release downloaded from this repository. See [Apple’s instructions](https://support.apple.com/102445).

Use the `+` button in Accessibility to add **Applications → CapsTalk** if it is absent. If macOS requests **Input Monitoring**, enable that too, then quit and reopen CapsTalk if requested. When updating, quit CapsTalk before replacing it; you may need to turn Accessibility off and on or remove and re-add its entry for the new build.

The app starts muted after permission is granted. Choose **Launch at Login** in its menu to start it automatically. The speaking-level slider changes your microphone’s system input gain while talking.

### Build from source

With Apple’s Command Line Tools installed (`xcode-select --install`):

```sh
./scripts/install.sh
```

This builds and installs `/Applications/CapsTalk.app`, then opens it.

## Behavior and compatibility

CapsTalk uses the hardware input mute control when available, otherwise sets input volume to zero and restores the speaking level while held. It covers all channels of the **default input device**. Set your meeting app to use that same microphone and leave its own in-app mute off; CapsTalk cannot override an app's separate mute button.

Some USB, Bluetooth, aggregate, and virtual devices expose neither a writable input mute nor a writable input-volume control. CapsTalk displays an error for these devices. With volume-based muting, another app can briefly change the system gain before CapsTalk's 250 ms mute check resets it. Secure keyboard input pauses push-to-talk. Switching input devices, sleep, losing the active user session, or interruption of keyboard capture requires a fresh press before talking again.

Caps Lock is mapped to **F20**, which provides normal press/release events, using Apple's [IOKit key-remapping API](https://developer.apple.com/library/archive/technotes/tn2450/_index.html). A [Quartz event tap](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)) consumes F20 before apps receive it. An actual F20 key also acts as push-to-talk while CapsTalk is enabled. Other existing key mappings are preserved. Other keyboard-remapping utilities can conflict with this mapping.

A small recovery process watches the app through a pipe. If CapsTalk crashes or is force-quit, it attempts to mute the inputs it controlled and restore the Caps Lock mapping. Original microphone settings remain recorded for the next launch. Recovery is best-effort if hardware disappears, permissions are revoked, or both processes are killed.

Recovery shares a session lock with the app and checks a unique session identifier, so a delayed watchdog cannot undo a newer launch. Changes enter the in-memory recovery journal only after the file is saved successfully. A release invalidates queued unmute requests; authorization is checked again around device reads and writes. If release happens during an in-flight device write, CapsTalk reasserts mute as soon as that call returns. A failed write to an old input does not prevent muting the newly selected input, and failed startup steps can be retried from the menu.

CapsTalk does not capture or record audio and does not need microphone-recording permission. The app has no network dependencies. Builds use Hardened Runtime and default to ad hoc signing; a rebuild may require re-adding the app to macOS privacy settings. Set `CAPSTALK_SIGNING_IDENTITY` when building to use your own signing certificate.

## Develop and verify

```sh
swift build
./scripts/test.sh
./scripts/build-app.sh
```

The tests exercise microphone gain/mute behavior, multichannel errors, input changes, failed journal writes and retries, release during delayed device operations, session ownership and recovery locking, startup retries, and preservation of existing key mappings with fake hardware. They run with Command Line Tools alone and never change the real microphone or keyboard. Global physical key capture still needs a manual check after granting permissions.

The app icon is bundled in `Resources/CapsTalk.icns`. Its vector drawing can be regenerated with `swift scripts/generate-icon.swift Resources`. To refresh the Finder icon of an existing installation without rebuilding or changing its signing identity, run:

```sh
swift scripts/apply-finder-icon.swift Resources/CapsTalk.icns /Applications/CapsTalk.app
```

Read-only diagnostics:

```sh
/Applications/CapsTalk.app/Contents/MacOS/CapsTalk --diagnose
```

Emergency restoration, after quitting CapsTalk:

```sh
/Applications/CapsTalk.app/Contents/MacOS/CapsTalk --restore
```

The session journal is stored in `~/Library/Application Support/CapsTalk/session.json`. To uninstall, disable Launch at Login, quit CapsTalk from its menu, and remove the installed app.

## Build the installer

On macOS, with Command Line Tools and Python 3.10 or newer installed:

```sh
./scripts/build-dmg.sh
```

This builds both processor architectures and packages `dist/CapsTalk-1.1.0-universal.dmg`, along with `dist/SHA256SUMS.txt`. Pinned Python packaging tools are installed into an isolated environment under `.build/`; they are not included in the app. The DMG contains CapsTalk, an Applications shortcut, a visual drag-and-drop layout, and a one-page setup guide. The script never replaces a running installation.

For a notarized release, set `CAPSTALK_SIGNING_IDENTITY` to a **Developer ID Application** identity and `CAPSTALK_NOTARY_PROFILE` to a keychain profile created with Apple’s `notarytool`. The packaging script signs with Hardened Runtime, submits the app and DMG to Apple, and staples their tickets. Credentials stay in the keychain and are not bundled or committed.
