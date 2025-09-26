import SwiftUI

struct DebugView: View {
    @State private var snapshotCount: Int = 0
    @State private var ftsCount: Int = 0
    @State private var rows: [DB.SnapshotRow] = []
    @State private var reindexing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button("Refresh") { refresh() }
                Button("Reveal DB in Finder") { reveal() }
                Button("Clear FTS") { try? DB.shared.clearFTS(); refresh() }
                Button(reindexing ? "Reindexing…" : "Reindex from Files") {
                    reindexing = true
                    DispatchQueue.global(qos: .utility).async {
                        Indexer.shared.rebuildFTSFromFiles()
                        DispatchQueue.main.async { reindexing = false; refresh() }
                    }
                }
                Button("Compact Older") {
                    DispatchQueue.global(qos: .utility).async {
                        Compactor().compactOlderSnapshots()
                        DispatchQueue.main.async { refresh() }
                    }
                }
            }
            HStack {
                Text("Snapshots: \(snapshotCount)")
                Text("FTS rows: \(ftsCount)")
            }
            List(rows, id: \.self) { r in
                HStack {
                    Text("#\(r.id)")
                        .monospaced()
                    Text("\(Date(timeIntervalSince1970: TimeInterval(r.startedAtMs)/1000).description)")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(r.path)
                        .lineLimit(1)
                        .font(.caption)
                }
            }
        }
        .padding()
        .onAppear { refresh() }
        .frame(minWidth: 700, minHeight: 400)
    }

    private func refresh() {
        snapshotCount = (try? DB.shared.snapshotCount()) ?? 0
        ftsCount = (try? DB.shared.ftsCount()) ?? 0
        rows = (try? DB.shared.listSnapshots(limit: 100)) ?? []
    }

    private func reveal() {
        guard let url = DB.shared.dbURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}


