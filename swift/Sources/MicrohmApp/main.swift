import AppKit
import MicrohmCore
import MicrohmShared

// Entry point: the AppKit app, as a plain SwiftPM executable or inside the Microhm.app
// that scripts/build-app.sh builds. One app per state directory (`MICROHM_HOME`, default
// ~/.micro-harness-manager-swift); logs go to its app.log.

StartupTimes.markMain()
_ = try? MicrohmPaths.ensureDirectory(MicrohmPaths.home)
Log.shared.open(MicrohmPaths.appLog)

let app = NSApplication.shared
app.setActivationPolicy(.regular)

/// Takes the registry's instance lock (Java's `lockInstance`). A background host holding it
/// (the app was closed while sessions ran) is stopped and the lock taken over; anything
/// else holding it is another app. A lock that cannot even be attempted runs unguarded.
func lockInstance() -> InstanceLock.Result {
    let registryFile = RegistryPaths.resolve()
    var lock = InstanceLock.tryAcquire(registryFile)
    if lock == .HELD {
        // a host that just took the lock writes its record right after; give it a moment
        for _ in 0..<20 where HostOwner.read(registryFile) == nil {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if HostOwner.read(registryFile) != nil, HostOwner.stop(registryFile, 5) {
            lock = InstanceLock.acquire(registryFile, 5)
        }
    }
    return lock
}

switch lockInstance() {
case .ACQUIRED:
    break
case .HELD:
    Log.warn("another instance holds \(InstanceLock.lockFile(RegistryPaths.resolve()).path); exiting", tag: "app")
    // bring the running one forward instead of opening a second window on the same state
    let me = ProcessInfo.processInfo.processIdentifier
    let others = NSWorkspace.shared.runningApplications.filter {
        $0.processIdentifier != me && $0.executableURL?.lastPathComponent == "Microhm"
    }
    if let other = others.first {
        other.activate()
    } else {
        let alert = NSAlert()
        alert.messageText = "\(AppModel.appName) is already running"
        alert.informativeText = "Another \(AppModel.appName) is using \(MicrohmPaths.home.path)."
        alert.alertStyle = .critical
        app.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    exit(1)
case .UNAVAILABLE:
    Log.warn("instance lock unavailable; running unguarded", tag: "app")
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
