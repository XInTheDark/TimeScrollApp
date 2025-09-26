import SwiftUI

struct StatsView: View {
    @State private var snapshotCount: Int = 0
    @State private var storageBytes: Int64 = 0
    @State private var avgBytes: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Snapshots: ")
                Text("\(snapshotCount)").bold()
            }
            HStack {
                Text("Storage: ")
                Text(byteString(storageBytes)).bold()
            }
            HStack {
                Text("Avg snapshot size: ")
                Text(byteString(avgBytes)).bold()
            }
            Button("Refresh") { refresh() }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        snapshotCount = (try? DB.shared.snapshotCount()) ?? 0
        avgBytes = (try? DB.shared.avgSnapshotBytes()) ?? 0
        let dir = SnapshotStore.shared.snapshotsDir
        DispatchQueue.global(qos: .utility).async {
            let size = dirSize(dir)
            DispatchQueue.main.async {
                storageBytes = size
            }
        }
    }

    private func dirSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in enumerator {
            if let vals = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), vals.isRegularFile == true {
                total += Int64(vals.fileSize ?? 0)
            }
        }
        return total
    }

    private func byteString(_ n: Int64) -> String {
        let units = ["B","KB","MB","GB","TB"]
        var size = Double(n)
        var idx = 0
        while size > 1024 && idx < units.count-1 { size /= 1024; idx += 1 }
        return String(format: "%.2f %@", size, units[idx])
    }
}

