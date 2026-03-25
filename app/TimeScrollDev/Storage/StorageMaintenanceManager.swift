import Foundation

final class StorageMaintenanceManager {
    static let shared = StorageMaintenanceManager()

    private let workQueue = DispatchQueue(label: "TimeScroll.StorageMaintenance", qos: .utility)
    private let stateQueue = DispatchQueue(label: "TimeScroll.StorageMaintenance.State")
    private var timer: Timer?
    private var running = false

    private init() {}

    func start() {
        guard timer == nil else { return }

        let scheduled = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            self?.runIfNeeded()
        }
        scheduled.tolerance = 5 * 60
        timer = scheduled

        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            self?.runIfNeeded()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func runIfNeeded(forceMaintenance: Bool = false, afterLargeDelete: Bool = false) {
        stateQueue.sync {
            guard !running else { return }
            running = true
            workQueue.async { [weak self] in
                defer {
                    self?.stateQueue.async {
                        self?.running = false
                    }
                }
                self?.performMaintenance(forceMaintenance: forceMaintenance, afterLargeDelete: afterLargeDelete)
            }
        }
    }

    private func performMaintenance(forceMaintenance: Bool, afterLargeDelete: Bool) {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: "settings.autoCompactEnabled") != nil
            ? defaults.bool(forKey: "settings.autoCompactEnabled")
            : false {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let lastCompaction = Int64(defaults.object(forKey: Self.lastCompactionKey) != nil
                ? defaults.double(forKey: Self.lastCompactionKey)
                : 0)
            if forceMaintenance || nowMs - lastCompaction >= Self.compactionIntervalMs {
                do {
                    if try Compactor().compactOlderSnapshots() {
                        defaults.set(Double(nowMs), forKey: Self.lastCompactionKey)
                    }
                } catch {
                }
            }
        }

        DB.shared.pruneOldOCRBoxesIfConfigured()
        DB.shared.runAutomaticMaintenance(force: forceMaintenance, afterLargeDelete: afterLargeDelete)
    }
}

private extension StorageMaintenanceManager {
    static let lastCompactionKey = "maintenance.lastAutoCompactionAtMs"
    static let compactionIntervalMs: Int64 = 12 * 60 * 60 * 1000
}
