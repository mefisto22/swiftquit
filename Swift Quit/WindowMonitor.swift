//
//  WindowMonitor.swift
//  Swift Quit
//
//  Watches the Accessibility window lists of running apps and reports when an
//  app closes its last window. This replaces Swindler, whose window-destroyed
//  events are no longer delivered reliably on macOS 26 and later.
//

import AppKit
import ApplicationServices

final class WindowMonitor {

    static let shared = WindowMonitor()

    /// Called on the main queue when an app goes from having windows to having none.
    var onLastWindowClosed: ((pid_t) -> Void)?

    /// Called on the main queue when the user clicks a window's close button.
    /// Some apps (e.g. Discord) hide themselves instead of closing the window,
    /// so no window ever disappears from the window list.
    var onCloseButtonClicked: ((pid_t) -> Void)?

    // The frontmost app is polled on every tick, all other apps every few ticks.
    private static let pollInterval: TimeInterval = 0.5
    private static let backgroundPollEveryNthTick = 4
    // After a Space change the window lists need a moment to settle.
    private static let spaceChangeSettleTime: DispatchTimeInterval = .milliseconds(1500)
    private static let messagingTimeout: Float = 0.25

    private struct ApplicationSnapshot {
        let processIdentifier: pid_t
        let isHidden: Bool
    }

    private struct KnownWindow {
        let element: AXUIElement
        // Space epoch in which the window was last seen in the AX window list.
        var lastSeenEpoch: Int
    }

    private final class TrackedApplication {
        let element: AXUIElement
        var windows: [KnownWindow] = []

        init(processIdentifier: pid_t) {
            element = AXUIElementCreateApplication(processIdentifier)
            AXUIElementSetMessagingTimeout(element, WindowMonitor.messagingTimeout)
        }
    }

    // Everything below is only touched on `queue`.
    private let queue = DispatchQueue(label: "Swift-Quit.window-monitor", qos: .utility)
    private var trackedApplications: [pid_t: TrackedApplication] = [:]
    // Incremented on every Space change. The AX window list only contains the
    // windows of the current Space, so a window that is missing from it is only
    // treated as closed if it was seen in the same Space before.
    private var spaceEpoch = 0
    private var settleDeadline = DispatchTime.now()
    private var isPaused = false

    // Only touched on the main queue.
    private var timer: Timer?
    private var tick = 0
    private var notificationObservers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?

    private init() {}

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard timer == nil else { return }

        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), WindowMonitor.messagingTimeout)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
            notificationObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main, using: handler))
        }
        observe(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in self?.spaceDidChange() }
        observe(NSWorkspace.screensDidWakeNotification) { [weak self] _ in self?.setPaused(false) }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in self?.setPaused(false) }
        observe(NSWorkspace.screensDidSleepNotification) { [weak self] _ in self?.setPaused(true) }
        observe(NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in self?.setPaused(true) }
        observe(NSWorkspace.didDeactivateApplicationNotification) { [weak self] notification in
            // An app that just lost focus may have closed its last window.
            if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.poll(applications: [application])
            }
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] notification in
            if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                let processIdentifier = application.processIdentifier
                self?.queue.async { self?.trackedApplications[processIdentifier] = nil }
            }
        }

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMouseDown(at: NSEvent.mouseLocation)
        }

        let timer = Timer(timeInterval: WindowMonitor.pollInterval, repeats: true) { [weak self] _ in self?.timerFired() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        log.notice("Window monitoring started")
        poll(applications: NSWorkspace.shared.runningApplications)
    }

    /// Re-reads the window list of an app and reports on the main queue whether
    /// it still has any window, either in the AX window list (including other
    /// Spaces it was seen on) or visible on screen according to the WindowServer.
    func hasWindows(processIdentifier: pid_t, completion: @escaping (Bool) -> Void) {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
            completion(false)
            return
        }
        let snapshot = ApplicationSnapshot(processIdentifier: processIdentifier, isHidden: application.isHidden)
        queue.async {
            let knownWindowCount = self.update(snapshot)
            // If the window list can't be read, assume the app still has windows.
            let hasWindows = (knownWindowCount ?? 1) > 0 || WindowMonitor.hasVisibleWindow(processIdentifier: processIdentifier)
            DispatchQueue.main.async { completion(hasWindows) }
        }
    }

    // MARK: - Polling

    private func timerFired() {
        tick += 1
        if tick % WindowMonitor.backgroundPollEveryNthTick == 0 {
            poll(applications: NSWorkspace.shared.runningApplications)
        } else if let frontmost = NSWorkspace.shared.frontmostApplication {
            poll(applications: [frontmost])
        }
    }

    private func poll(applications: [NSRunningApplication]) {
        // NSRunningApplication properties are updated on the main run loop,
        // so take the snapshot here and do the AX work in the background.
        let snapshots = applications
            .filter(WindowMonitor.shouldMonitor)
            .map { ApplicationSnapshot(processIdentifier: $0.processIdentifier, isHidden: $0.isHidden) }

        queue.async {
            guard !self.isPaused else { return }
            for snapshot in snapshots {
                let previousCount = self.trackedApplications[snapshot.processIdentifier]?.windows.count
                guard let currentCount = self.update(snapshot) else { continue }
                if previousCount != currentCount {
                    log.debug("pid \(snapshot.processIdentifier, privacy: .public): \(previousCount ?? -1, privacy: .public) -> \(currentCount, privacy: .public) windows")
                }

                if let previousCount, previousCount > 0, currentCount == 0 {
                    let processIdentifier = snapshot.processIdentifier
                    DispatchQueue.main.async { self.onLastWindowClosed?(processIdentifier) }
                }
            }
        }
    }

    /// Updates the known windows of an app and returns how many it has, or nil
    /// if its window list couldn't be read (busy, still launching, no AX support).
    private func update(_ snapshot: ApplicationSnapshot) -> Int? {
        dispatchPrecondition(condition: .onQueue(queue))
        let processIdentifier = snapshot.processIdentifier

        let tracked: TrackedApplication
        if let existing = trackedApplications[processIdentifier] {
            tracked = existing
        } else {
            tracked = TrackedApplication(processIdentifier: processIdentifier)
            trackedApplications[processIdentifier] = tracked
        }

        guard let currentWindows = WindowMonitor.windows(of: tracked.element) else {
            log.debug("pid \(processIdentifier, privacy: .public): window list unavailable")
            return nil
        }

        let epoch = spaceEpoch
        let isSettling = DispatchTime.now() < settleDeadline
        // Hidden apps can report an empty window list; never treat that as closing.
        let keepMissingWindows = isSettling || snapshot.isHidden

        var updatedWindows: [KnownWindow] = []
        for known in tracked.windows {
            if let current = currentWindows.first(where: { CFEqual($0, known.element) }) {
                let lastSeenEpoch = isSettling ? known.lastSeenEpoch : epoch
                updatedWindows.append(KnownWindow(element: current, lastSeenEpoch: lastSeenEpoch))
                continue
            }
            if WindowMonitor.isDestroyed(known.element) {
                continue
            }
            if !keepMissingWindows && known.lastSeenEpoch == epoch {
                // Seen in this Space before and gone now: closed.
                continue
            }
            // Probably on another Space.
            updatedWindows.append(known)
        }
        for window in currentWindows where !updatedWindows.contains(where: { CFEqual($0.element, window) }) {
            updatedWindows.append(KnownWindow(element: window, lastSeenEpoch: isSettling ? -1 : epoch))
        }

        tracked.windows = updatedWindows
        return updatedWindows.count
    }

    private func spaceDidChange() {
        let settleDeadline = DispatchTime.now() + WindowMonitor.spaceChangeSettleTime
        queue.async {
            self.spaceEpoch += 1
            self.settleDeadline = settleDeadline
        }
    }

    private func setPaused(_ paused: Bool) {
        let settleDeadline = DispatchTime.now() + WindowMonitor.spaceChangeSettleTime
        queue.async {
            self.isPaused = paused
            if !paused {
                // The current Space may have changed while the screen was off.
                self.spaceEpoch += 1
                self.settleDeadline = settleDeadline
            }
        }
    }

    // MARK: - Close button clicks

    private func handleMouseDown(at cocoaLocation: NSPoint) {
        // AX uses top-left based screen coordinates.
        guard let mainScreenHeight = NSScreen.screens.first?.frame.height else { return }
        let location = CGPoint(x: cocoaLocation.x, y: mainScreenHeight - cocoaLocation.y)

        // The hit test asks another app over AX and can block while it is busy.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let processIdentifier = WindowMonitor.closeButtonOwner(at: location) else { return }
            DispatchQueue.main.async { self.onCloseButtonClicked?(processIdentifier) }
        }
    }

    private static func closeButtonOwner(at location: CGPoint) -> pid_t? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(location.x), Float(location.y), &element) == .success,
              let element else {
            return nil
        }

        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
              subrole as? String == kAXCloseButtonSubrole else {
            return nil
        }

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success, processIdentifier != 0 else {
            return nil
        }
        return processIdentifier
    }

    // MARK: - Helpers

    private static func shouldMonitor(_ application: NSRunningApplication) -> Bool {
        // Menu bar apps and background agents are never quit (issue #58).
        return application.activationPolicy == .regular
            && application.isFinishedLaunching
            && !application.isTerminated
            && application.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }

    private static func windows(of applicationElement: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &value)
        switch error {
        case .success:
            return value as? [AXUIElement] ?? []
        case .noValue:
            return []
        default:
            return nil
        }
    }

    private static func isDestroyed(_ windowElement: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(windowElement, kAXRoleAttribute as CFString, &value) == .invalidUIElement
    }

    /// Safety net for apps whose AX window list is incomplete: a normal-level,
    /// non-transparent window of the app that is currently on screen.
    private static func hasVisibleWindow(processIdentifier: pid_t) -> Bool {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return true
        }
        return windowInfo.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) > 0,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                return false
            }
            return bounds.width > 1 && bounds.height > 1
        }
    }
}
