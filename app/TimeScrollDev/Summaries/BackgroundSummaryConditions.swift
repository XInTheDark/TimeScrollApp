import CoreGraphics
import Foundation
import IOKit.ps

/// Whether the Mac can spare the model's memory and GPU right now.
struct BackgroundSummaryConditions: Equatable {
  enum Allowance: Equatable {
    case none
    /// On battery: only the latest finished day, week and month.
    case recentOnly
    /// On power: catching up too.
    case all
  }

  static let minimumIdleSeconds: TimeInterval = 180
  static let minimumBatteryPercent = 50

  var onACPower: Bool
  var batteryPercent: Int?
  var lowPowerMode: Bool
  var thermalNominal: Bool
  var idleSeconds: TimeInterval

  var allowance: Allowance {
    guard thermalNominal, !lowPowerMode, idleSeconds >= Self.minimumIdleSeconds else { return .none }
    if onACPower { return .all }
    guard let batteryPercent, batteryPercent > Self.minimumBatteryPercent else { return .none }
    return .recentOnly
  }

  static func current() -> BackgroundSummaryConditions {
    let anyInput = CGEventType(rawValue: ~0)!
    let power = powerState()
    return BackgroundSummaryConditions(
      onACPower: power.onAC, batteryPercent: power.percent,
      lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
      thermalNominal: ProcessInfo.processInfo.thermalState == .nominal,
      idleSeconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput))
  }

  private static func powerState() -> (onAC: Bool, percent: Int?) {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (true, nil) }
    let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
    let onAC = type != kIOPSBatteryPowerValue
    guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (onAC, nil) }
    for source in list {
      guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
            let current = description[kIOPSCurrentCapacityKey] as? Int,
            let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
      return (onAC, current * 100 / maximum)
    }
    return (onAC, nil)
  }
}
