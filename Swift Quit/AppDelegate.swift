//
//  AppDelegate.swift
//  Swift Quit
//
//  Created by Johnny Baird on 5/25/22.
//

import Cocoa
import ApplicationServices

var userDefaults = UserDefaults.standard
var swiftQuitSettings = SwiftQuit.getSettings()
var swiftQuitExcludedApps = SwiftQuit.getExcludedApps()
let storyboard = NSStoryboard(name: "Main", bundle: nil)
var settingsWindow = (storyboard.instantiateController(withIdentifier: "settings") as! NSWindowController)
var menu = NSMenu()
var statusItem: NSStatusItem!

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    private var accessibilityItem: NSMenuItem?
    private var accessibilityTimer: Timer?

    func applicationDidFinishLaunching(_ aNotification: Notification) {

        SwiftQuit.migrateLaunchAtLogin()

        self.loadMenu()

        if(swiftQuitSettings["menubarIconEnabled"] == "false"){
            SwiftQuit.hideMenu()
        }

        if (swiftQuitSettings["launchHidden"] == "false"){
            self.openSettings()
        }

        let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(promptOptions) {
            log.notice("Accessibility access granted")
            SwiftQuit.activateAutomaticAppClosing()
        } else {
            log.notice("Accessibility access missing; waiting for it")
            waitForAccessibilityPermission()
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if (!flag) {
            openSettings();
        }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    /// Starts watching windows as soon as Accessibility access is granted, so
    /// the app doesn't have to be relaunched.
    func waitForAccessibilityPermission() {
        let item = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(NSMenuItem.separator(), at: 1)
        accessibilityItem = item

        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            log.notice("Accessibility access granted")
            timer.invalidate()
            self?.accessibilityTimer = nil
            if let item = self?.accessibilityItem {
                menu.removeItem(at: menu.index(of: item) + 1)
                menu.removeItem(item)
            }
            SwiftQuit.activateAutomaticAppClosing()
        }
    }

    @objc func openAccessibilitySettings() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Access Required"
        alert.informativeText = """
        Swift Quit needs Accessibility access to see when app windows are closed.

        Open System Settings → Privacy & Security → Accessibility and turn on Swift Quit.

        If Swift Quit is already listed and turned on, an older copy of the app is listed: remove it with the − button, then add this one again.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        activateApp()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func loadMenu(){
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(named: "MenuIcon")
            button.image?.size = NSSize(width: 18.0, height: 18.0)
            button.image?.isTemplate = true
            button.toolTip = "Swift Quit"
        }
        statusItem.isVisible = true
        let openSettings = NSMenuItem(title: "Settings...", action: #selector(openSettings) , keyEquivalent: ",")
        openSettings.target = self
        menu.addItem(openSettings)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func openSettings() {
        settingsWindow.showWindow(self)
        settingsWindow.shouldCloseDocument = true
        activateApp()
        settingsWindow.window?.makeKeyAndOrderFront(nil)
        settingsWindow.window?.orderFrontRegardless()
    }

    func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }


}
