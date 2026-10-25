# Swift Quit
Swift Quit enables automatic quitting of macOS apps when closing their windows (clicking the red x). It can be configured to quit when the last window of any app closed, or restricted to a specific list of apps. Additionally, you can exclude apps you dont want to quit automatically.

# macOS 26 / 27 Compatibility (v1.6)
Version 1.6 works on macOS 13 Ventura through macOS 27, on Apple silicon and Intel.

- Window tracking no longer uses Swindler, whose window-destroyed events stopped arriving reliably on macOS 26 and 27. Swift Quit now reads each app's window list through the Accessibility API and quits an app when its window count drops to zero and stays there for the close delay.
- Windows on other desktops (Spaces) and in full screen are kept track of, so switching desktops doesn't quit apps.
- Apps that hide themselves when the close button is clicked (Discord, for example) are quit too.
- Menu bar apps and background agents are never quit.
- Excluded/included apps match correctly when the app name contains non-ASCII characters.
- Launch at login uses the system Login Items service (`SMAppService`) instead of a helper app. You can also see or change it in System Settings → General → Login Items.
- If Accessibility access is missing, Swift Quit waits for it instead of quitting, and starts working as soon as access is granted.
- The project has no third-party dependencies any more.

# Use At Your Own Risk
Some users have reported issues with unwanted closing of windows or other problems so use at your own risk.

# Website
https://swiftquit.com

# Download
https://swiftquit.com/downloads/Swift%20Quit.zip

# Installation Instructions
https://www.youtube.com/watch?v=WwWF-yekX-U

1. Install via Homebrew "brew install --cask swift-quit"
2. Or download from https://swiftquit.com, unzip, and move app to applications folder.
------------
3. Open finder to applications folder and ctrl+click swift quit.app then select open (You may need to do this twice)
5. When prompted click open system preferences
6. Unlock system preferences by clicking the lock icon
7. Drag Swift Quit.app into the accessibility list and enable it
8. Double click Swift Quit.app
9. Optionally enable start automatically in settings

# Upgrading To A New Version
In order to upgrade to a new version you must first remove the old version from System Settings → Privacy & Security → Accessibility (select it and click −). Then add the new version and turn it on. Builds that aren't signed with a Developer ID get a new code signature every time, so macOS treats each one as a different app.

# Building
Open `Swift Quit.xcodeproj` in Xcode 15 or later and run the "Swift Quit" scheme, or from Terminal:

```
xcodebuild -project "Swift Quit.xcodeproj" -scheme "Swift Quit" -configuration Release build
```

To distribute builds, set your own team in Signing & Capabilities and sign with a Developer ID certificate, so the Accessibility permission survives updates.
