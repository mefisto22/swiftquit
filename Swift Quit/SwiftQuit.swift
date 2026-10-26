//
//  SwiftQuit.swift
//  Swift Quit
//
//  Created by Johnny Baird on 5/25/22.
//

import Foundation
import AppKit
import ServiceManagement
import os

let log = Logger(subsystem: "onebadidea.Swift-Quit", category: "SwiftQuit")

class SwiftQuit {

    private static var pendingTerminations = Set<pid_t>()
    private static var pendingHiddenTerminations = Set<pid_t>()

    private static let excludedSystemApplicationPaths: Set<String> = [
        "/System/Library/CoreServices/Spotlight.app",
        "/System/Library/CoreServices/Finder.app",
        "/System/Library/CoreServices/NotificationCenter.app",
        "/System/Library/CoreServices/Dock.app",
        "/System/Library/CoreServices/loginwindow.app",
        "/System/Library/CoreServices/ControlCenter.app",
        "/System/Library/CoreServices/SystemUIServer.app"
    ]

    private static let excludedSystemBundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.loginwindow",
        "com.apple.Spotlight",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.systemuiserver"
    ]

    /*
     Settings
     */

    @objc class func getSettings() -> [String:String] {
        return userDefaults.object(forKey: "SwiftQuitSettings") as? [String:String] ?? ["launchAtLogin":"false","menubarIconEnabled":"true","excludeBehaviour":"excludeApps","launchHidden":"true","closeDelay":"2"]
    }

    @objc class func updateSettings(){
        userDefaults.set(swiftQuitSettings, forKey: "SwiftQuitSettings")
    }

    @objc class func getExcludedApps() -> [String] {
        return userDefaults.object(forKey: "SwiftQuitExcludedApps") as? [String] ?? []
    }

    @objc class func updateExcludedApps(){
        userDefaults.set(swiftQuitExcludedApps, forKey: "SwiftQuitExcludedApps")
    }

    @objc class func enableExcludedApps(){
        swiftQuitSettings["excludeBehaviour"] = "excludeApps"
        updateSettings()
    }

    @objc class func enableIncludedApps(){
        swiftQuitSettings["excludeBehaviour"] = "includeApps"
        updateSettings()
    }

    @objc class func enableMenubarIcon(){
        swiftQuitSettings["menubarIconEnabled"] = "true"
        updateSettings()
    }
    @objc class func disableMenubarIcon(){
        swiftQuitSettings["menubarIconEnabled"] = "false"
        updateSettings()
    }

    /*
     Launch at login, using SMAppService (macOS 13+) instead of a helper app.
     */

    class func isLaunchAtLoginEnabled() -> Bool {
        return SMAppService.mainApp.status == .enabled
    }

    class func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
        swiftQuitSettings["launchAtLogin"] = enabled ? "true" : "false"
        updateSettings()
    }

    /// Versions up to 1.5 used a login helper app that no longer exists in the
    /// bundle. Register the app itself once for users who had it enabled.
    class func migrateLaunchAtLogin() {
        guard !userDefaults.bool(forKey: "SwiftQuitLaunchAtLoginMigrated") else { return }
        userDefaults.set(true, forKey: "SwiftQuitLaunchAtLoginMigrated")

        if swiftQuitSettings["launchAtLogin"] == "true" && SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
        }
    }

    @objc class func enableLaunchHidden(){
        swiftQuitSettings["launchHidden"] = "true"
        updateSettings()
    }
    @objc class func disableLaunchHidden(){
        swiftQuitSettings["launchHidden"] = "false"
        updateSettings()
    }

    @objc class func setCloseDelay(_ delay: String){
        swiftQuitSettings["closeDelay"] = delay
        updateSettings()
    }

    class func closeDelay() -> Int {
        return max(0, Int(swiftQuitSettings["closeDelay"] ?? "2") ?? 2)
    }

    /*
     Automatic app closing
     */

    @objc class func activateAutomaticAppClosing(){
        let monitor = WindowMonitor.shared
        monitor.onLastWindowClosed = { processIdentifier in
            lastWindowClosed(pid: processIdentifier)
        }
        monitor.onCloseButtonClicked = { processIdentifier in
            closeButtonClicked(pid: processIdentifier)
        }
        monitor.start()
    }

    class func lastWindowClosed(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid),
              canCloseApplication(app: app),
              !pendingTerminations.contains(pid) else {
            return
        }
        pendingTerminations.insert(pid)
        log.notice("\(app.localizedName ?? "<no_name>", privacy: .public) closed its last window; quitting in \(closeDelay())s")

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(closeDelay())) {
            WindowMonitor.shared.hasWindows(processIdentifier: pid) { hasWindows in
                pendingTerminations.remove(pid)

                if hasWindows {
                    log.notice("\(app.localizedName ?? "<no_name>", privacy: .public) has a window again; not quitting")
                    return
                }
                if !app.isTerminated && canCloseApplication(app: app) {
                    terminateApplication(app: app)
                }
            }
        }
    }

    /// Apps like Discord hide themselves when their close button is clicked
    /// instead of closing the window (issues #25, #38).
    class func closeButtonClicked(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid),
              !app.isHidden,
              canCloseApplication(app: app),
              !pendingHiddenTerminations.contains(pid) else {
            return
        }
        pendingHiddenTerminations.insert(pid)
        log.notice("Close button clicked in \(app.localizedName ?? "<no_name>", privacy: .public)")

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(closeDelay())) {
            guard !app.isTerminated, canCloseApplication(app: app) else {
                pendingHiddenTerminations.remove(pid)
                return
            }
            if app.isHidden {
                pendingHiddenTerminations.remove(pid)
                terminateApplication(app: app)
                return
            }
            // Normally the window list shows the last window closing. If it
            // doesn't, check once more and log what still counts as a window.
            WindowMonitor.shared.hasWindows(processIdentifier: pid) { hasWindows in
                pendingHiddenTerminations.remove(pid)
                guard !app.isTerminated, !pendingTerminations.contains(pid) else { return }

                if !hasWindows {
                    terminateApplication(app: app)
                    return
                }
                WindowMonitor.shared.describeWindows(processIdentifier: pid) { description in
                    log.notice("\(app.localizedName ?? "<no_name>", privacy: .public) still has windows; not quitting. Windows: \(description, privacy: .public)")
                }
            }
        }
    }

    /// Whether Swift Quit may quit this app: not itself, not a menu bar app or
    /// protected system service, and allowed by the user's app list.
    class func canCloseApplication(app: NSRunningApplication) -> Bool {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.isFinishedLaunching,
              app.activationPolicy == .regular,
              let bundleURL = app.bundleURL else {
            return false
        }

        if let bundleIdentifier = app.bundleIdentifier, excludedSystemBundleIdentifiers.contains(bundleIdentifier) {
            return false
        }

        // Use the decoded file system path, which is what the settings UI
        // stores. URL.absoluteString percent-encodes non-ASCII names (#65).
        let applicationPath = bundleURL.standardizedFileURL.path
        if excludedSystemApplicationPaths.contains(applicationPath) {
            return false
        }

        return shouldCloseApplication(applicationPath: applicationPath)
    }

    class func shouldCloseApplication(applicationPath: String) -> Bool {
        let isListed = swiftQuitExcludedApps.contains { listedPath in
            normalizedPath(listedPath) == normalizedPath(applicationPath)
        }
        switch swiftQuitSettings["excludeBehaviour"] {
        case "includeApps":
            return isListed
        default:
            return !isListed
        }
    }

    private class func normalizedPath(_ path: String) -> String {
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    class func terminateApplication(app: NSRunningApplication) {
        log.notice("Quitting \(app.localizedName ?? "<no_name>", privacy: .public)")
        app.terminate()
    }

    class func hideMenu(){
        statusItem.isVisible = false
    }

    class func showMenu(){
        statusItem.isVisible = true
    }


}
