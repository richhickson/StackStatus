import AppKit
import SwiftUI
import UserNotifications

/// Wires everything together: settings, config, scheduler, state store,
/// status item, popover, settings window, sleep and wake, notifications.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var settings: AppSettings!
    private var vendorsModel: VendorsModel!
    private var notifier: Notifier!
    private var store: StateStore!
    private var http: HTTPClient!
    private var scheduler: PollScheduler!
    private var updateMonitor: UpdateMonitor!
    private var updateInstaller: UpdateInstaller!
    private var statusItemController: StatusItemController!
    private var popoverController: PopoverController!
    private var settingsWindow: NSWindow?
    private var settingsObservation: Any?
    private var popoverObservation: Any?
    private var autoInstallObservation: Any?

    /// Development aids, ignored unless set in the environment:
    /// STACKSTATUS_DEBUG_INTERVAL=<seconds> overrides the poll interval,
    /// STACKSTATUS_DEBUG_SHOW_POPOVER=1 opens the popover after the first poll,
    /// STACKSTATUS_DEBUG_SNAPSHOT=<file.png> renders the popover to a PNG after
    /// the first poll and quits (used for the README screenshot),
    /// STACKSTATUS_DEBUG_UPDATE_URL points update checks at a local fixture,
    /// STACKSTATUS_DEBUG_AUTO_INSTALL=1 installs the first update found without a click.
    private static func debugAdjusted(_ poll: PollSettings) -> PollSettings {
        var poll = poll
        if let raw = ProcessInfo.processInfo.environment["STACKSTATUS_DEBUG_INTERVAL"], let seconds = TimeInterval(raw), seconds >= 1 {
            poll.userInterval = seconds
        }
        return poll
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        settings = AppSettings()
        vendorsModel = VendorsModel(store: ConfigStore())
        notifier = Notifier(settings: settings)
        store = StateStore(vendors: vendorsModel.vendors, notifier: notifier)
        http = HTTPClient()
        updateMonitor = UpdateMonitor(settings: settings, http: http)
        updateInstaller = UpdateInstaller(session: http.session)
        updateMonitor.start()

        let store = self.store!
        scheduler = PollScheduler(
            http: http,
            prober: ProbeRunner(http: http),
            baseline: BaselineProber(http: http),
            settings: Self.debugAdjusted(settings.pollSettings),
            sink: { result in
                await MainActor.run { store.apply(result) }
            }
        )

        popoverController = PopoverController(
            store: store,
            settings: settings,
            updates: updateMonitor,
            installer: updateInstaller,
            actions: PopoverActions(
                refresh: { [weak self] in self?.refreshNow() },
                openSettings: { [weak self] in self?.openSettings() },
                quit: { NSApp.terminate(nil) }
            )
        )
        statusItemController = StatusItemController(store: store, settings: settings) { [weak self] in
            guard let self, let button = self.statusItemController.statusItem.button else { return }
            self.popoverController.toggle(relativeTo: button)
        }

        vendorsModel.onChange = { [weak self] vendors in
            guard let self else { return }
            self.store.setVendors(vendors)
            let scheduler = self.scheduler!
            Task { await scheduler.update(vendors: vendors) }
        }

        settingsObservation = settings.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let poll = Self.debugAdjusted(self.settings.pollSettings)
                let scheduler = self.scheduler!
                Task { await scheduler.update(settings: poll) }
            }

        if let path = ProcessInfo.processInfo.environment["STACKSTATUS_DEBUG_SNAPSHOT"] {
            popoverObservation = store.$hasPolled
                .filter { $0 }
                .first()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    // Give the view a moment to lay out with the fresh state.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.popoverController.writeSnapshot(to: path)
                        NSApp.terminate(nil)
                    }
                }
        }

        if ProcessInfo.processInfo.environment["STACKSTATUS_DEBUG_AUTO_INSTALL"] != nil {
            let installer = updateInstaller!
            autoInstallObservation = updateMonitor.$available
                .compactMap { $0 }
                .first()
                .receive(on: RunLoop.main)
                .sink { release in Task { await installer.install(release) } }
        }

        if ProcessInfo.processInfo.environment["STACKSTATUS_DEBUG_SHOW_POPOVER"] != nil {
            popoverObservation = store.$hasPolled
                .filter { $0 }
                .first()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self, let button = self.statusItemController.statusItem.button else { return }
                    self.popoverController.toggle(relativeTo: button)
                }
        }

        UNUserNotificationCenter.current().delegate = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.notifier.requestAuthorization()
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        let vendors = vendorsModel.vendors
        let scheduler = self.scheduler!
        store.setRefreshing(true)
        Task { await scheduler.start(vendors: vendors) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let scheduler = self.scheduler
        Task { await scheduler?.stop() }
    }

    // MARK: Actions

    private func refreshNow() {
        store.setRefreshing(true)
        let scheduler = self.scheduler!
        Task { await scheduler.refreshNow() }
    }

    private func openSettings() {
        popoverController.close()
        if settingsWindow == nil {
            let root = SettingsView(detector: PlatformDetector(http: http))
                .environmentObject(settings!)
                .environmentObject(vendorsModel!)
                .environmentObject(updateMonitor!)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "StackStatus Settings"
            window.contentViewController = NSHostingController(rootView: root)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Sleep and wake

    @objc private func willSleep() {
        let scheduler = self.scheduler!
        Task { await scheduler.systemWillSleep() }
    }

    @objc private func didWake() {
        let scheduler = self.scheduler!
        store.setRefreshing(true)
        Task {
            // Give the network a moment to come back before the first poll.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await scheduler.systemDidWake()
        }
    }

    // MARK: Notifications

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo[Notifier.urlKey] as? String
        if let raw, let url = URL(string: raw) {
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
