import Foundation
import IOKit.ps

/// Thin IOKit wrapper: are we running on battery right now?
enum PowerSourceIOKit {
    static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
            return false
        }
        return (type as String) == kIOPMBatteryPowerKey
    }
}
