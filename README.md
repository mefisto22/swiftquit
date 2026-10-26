# Swift Quit

Swift Quit quits macOS apps automatically when you close their last window (click the red ✕ or press ⌘W), the way apps behave on Windows. It can quit every app, or only the apps on a list you choose, and you can exclude apps you never want quit.

This is a maintained fork of [onebadidea/swiftquit](https://github.com/onebadidea/swiftquit), updated to work on macOS 26 and macOS 27.

## Download

**[Download Swift Quit 1.6.1](https://github.com/mefisto22/swiftquit/releases/latest/download/Swift-Quit.zip)** — or see all versions on the [Releases page](https://github.com/mefisto22/swiftquit/releases).

Requires macOS 13 Ventura or later. Runs natively on Apple silicon and Intel Macs.

## Installation

1. Download `Swift-Quit.zip`, open it, and move **Swift Quit.app** to your **Applications** folder.
2. Open Swift Quit. Because the app isn't notarized by Apple, macOS will say it can't verify it. Click **Done**, then go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the Swift Quit message. Confirm with **Open**.

   Alternatively, run this once in Terminal:

   ```
   xattr -dr com.apple.quarantine "/Applications/Swift Quit.app"
   ```

3. When asked, open **System Settings → Privacy & Security → Accessibility** and turn on **Swift Quit**. Swift Quit needs this to see when windows are closed. It starts working as soon as access is granted; you don't have to relaunch it.
4. Optionally, open Swift Quit's settings and turn on **Launch at Login**.

To open the settings, click the Swift Quit icon in the menu bar, or open the app again from the Applications folder if you've hidden the menu bar icon.

## Upgrading from an Earlier Version

1. Quit the old Swift Quit and replace it in the Applications folder with the new one.
2. Go to **System Settings → Privacy & Security → Accessibility**, select the old **Swift Quit** entry, and remove it with the **−** button. Turning the old entry off and on again is not enough.
3. Click **+**, choose **/Applications/Swift Quit.app**, and turn it on.

macOS ties the Accessibility permission to the app's code signature. Builds that aren't signed with an Apple Developer ID get a new signature every time, so macOS treats each version as a different app. Your settings and app list are kept.

## Settings

- **Quit:** all apps except the ones on the list, or only the apps on the list.
- **Close delay:** how many seconds to wait after the last window closes before quitting the app (default: 2). If a window opens again in that time, the app keeps running.
- **Launch at Login:** also shown in System Settings → General → Login Items.
- **Launch hidden** and **Show menu bar icon.**

Swift Quit never quits Finder, menu bar apps, or background agents. Apps with minimized windows, windows on other desktops (Spaces), or windows in full screen keep running.

## What's New in 1.6.1

- Apps that keep a closed window in their window list, such as Reminders, Calendar and Pages, are now quit when you close their last window. Before, they could stay open in the Dock with no window. Swift Quit now only counts windows that are on screen, minimized, or on another desktop.
- If an app keeps running after you click its close button, the log says which windows Swift Quit still counted (see [Troubleshooting](#troubleshooting)).

## What's New in 1.6

- Works on macOS 26 and 27. Window tracking no longer uses the Swindler library, whose window events stopped arriving reliably; Swift Quit now reads each app's window list through the Accessibility API.
- Switching desktops (Spaces) or using full screen doesn't quit apps.
- Apps that hide themselves when the close button is clicked, such as Discord, are quit too.
- Menu bar apps and background agents are never quit.
- The app list works with app names that contain non-English characters.
- Launch at login uses the system Login Items service instead of a helper app. If it was turned on in an earlier version, it's carried over.
- If Accessibility access is missing, Swift Quit waits for it instead of quitting.
- No third-party dependencies.

## Use at Your Own Risk

Swift Quit quits apps for you. Apps normally ask you to save unsaved changes before they quit, but test it with the apps you use, and add any app that behaves unexpectedly to the exclusion list.

## Troubleshooting

Swift Quit logs every decision it makes. To see why an app was or wasn't quit, run in Terminal:

```
/usr/bin/log show --last 10m --predicate 'subsystem == "onebadidea.Swift-Quit"' --style compact
```

If nothing gets quit at all, check that Swift Quit is turned on under Accessibility, and if it is, remove and re-add it as described in [Upgrading](#upgrading-from-an-earlier-version).

Please report problems on the [Issues page](https://github.com/mefisto22/swiftquit/issues).

## Building from Source

Open `Swift Quit.xcodeproj` in Xcode 15 or later and run the **Swift Quit** scheme, or from Terminal:

```
xcodebuild -project "Swift Quit.xcodeproj" -scheme "Swift Quit" -configuration Release build
```

To distribute builds that keep their Accessibility permission across updates, set your own team under Signing & Capabilities and sign with a Developer ID certificate.

## Credits

Swift Quit was created by [Johnny Baird (onebadidea)](https://github.com/onebadidea/swiftquit). Some fixes in 1.6 are based on open pull requests in the original repository.
