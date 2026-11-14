import Darwin
import Foundation

/// The current folder of the foreground process on a terminal device, from the process table.
/// Only the user's own processes are readable, which is all a terminal runs.
enum TimeWarpTerminalFolder {
  static func foregroundDirectory(ttyPath: String) -> String? {
    var info = stat()
    guard stat(ttyPath, &info) == 0 else { return nil }
    let device = UInt32(bitPattern: info.st_rdev)

    let capacity = Int(proc_listallpids(nil, 0)) + 64
    guard capacity > 64 else { return nil }
    var pids = [pid_t](repeating: 0, count: capacity)
    let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
    var fallback: pid_t?
    for pid in pids.prefix(max(0, count)) where pid > 0 {
      var bsd = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size, bsd.e_tdev == device else { continue }
      // The foreground job's process group owns the terminal.
      if bsd.pbi_pgid == bsd.e_tpgid, let folder = currentDirectory(of: pid) { return folder }
      if fallback == nil { fallback = pid }
    }
    return fallback.flatMap(currentDirectory(of:))
  }

  static func currentDirectory(of pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
      String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
    }
    return path.isEmpty ? nil : path
  }
}
