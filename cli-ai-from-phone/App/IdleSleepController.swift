import Foundation

/// Holds a macOS idle-sleep prevention activity only while remote control is
/// actually available. The activity is explicitly released instead of relying
/// on process termination, so stopping the connection immediately restores
/// the user's normal energy settings.
final class IdleSleepController {
    private let beginActivity: () -> NSObjectProtocol
    private let endActivity: (NSObjectProtocol) -> Void
    private var activity: NSObjectProtocol?

    init(
        beginActivity: @escaping () -> NSObjectProtocol = {
            ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "Steward is connected and waiting for remote commands")
        },
        endActivity: @escaping (NSObjectProtocol) -> Void = { activity in
            ProcessInfo.processInfo.endActivity(activity)
        }
    ) {
        self.beginActivity = beginActivity
        self.endActivity = endActivity
    }

    func update(keepMacAwake: Bool, connectionState: ConnectionState) {
        guard keepMacAwake, case .connected = connectionState else {
            releaseActivity()
            return
        }

        guard activity == nil else { return }
        activity = beginActivity()
    }

    deinit {
        releaseActivity()
    }

    private func releaseActivity() {
        guard let activity else { return }
        endActivity(activity)
        self.activity = nil
    }
}
