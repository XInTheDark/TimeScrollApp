import Foundation

extension StoragePaths {
    static func sharedLogURL(filename: String) -> URL {
        let logsDir = sharedSupportRoot().appendingPathComponent("Logs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: logsDir.path) {
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }
        return logsDir.appendingPathComponent(filename)
    }

    private static func sharedStateURL() -> URL {
        let sharedDir = sharedSupportRoot().appendingPathComponent(sharedSubdirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: sharedDir.path) {
            try? FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        }
        return sharedDir.appendingPathComponent(sharedStateFilename)
    }

    private static func readFallbackSharedState() -> NSMutableDictionary {
        let url = sharedStateURL()
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            return [:]
        }
        return NSMutableDictionary(dictionary: dict)
    }

    private static func writeFallbackSharedState(_ state: NSMutableDictionary) {
        let url = sharedStateURL()
        guard let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0) else {
            return
        }

        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                let _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    static func sharedObject(forKey key: String) -> Any? {
        if canUseManagedAppGroupAccess() {
            return (UserDefaults(suiteName: appGroupID) ?? .standard).object(forKey: key)
        }

        return sharedStateQueue.sync {
            readFallbackSharedState()[key]
        }
    }

    static func sharedData(forKey key: String) -> Data? {
        sharedObject(forKey: key) as? Data
    }

    static func sharedString(forKey key: String) -> String? {
        sharedObject(forKey: key) as? String
    }

    static func sharedBool(forKey key: String) -> Bool {
        if let value = sharedObject(forKey: key) as? Bool {
            return value
        }
        if let number = sharedObject(forKey: key) as? NSNumber {
            return number.boolValue
        }
        return false
    }

    static func setShared(_ value: Any?, forKey key: String) {
        if canUseManagedAppGroupAccess() {
            let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
            defaults.set(value, forKey: key)
            return
        }

        sharedStateQueue.sync {
            let state = readFallbackSharedState()
            if let value {
                state[key] = value
            } else {
                state.removeObject(forKey: key)
            }
            writeFallbackSharedState(state)
        }
    }

    static func removeSharedObject(forKey key: String) {
        setShared(nil, forKey: key)
    }

    static func synchronizeShared() {
        if canUseManagedAppGroupAccess() {
            (UserDefaults(suiteName: appGroupID) ?? .standard).synchronize()
        }
    }
}
