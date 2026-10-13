import Foundation
import SwiftData

@Model
final class DeviceStatus {
    var deviceID: String
    var deviceName: String
    var lastSyncTimestamp: Date
    var isOnline: Bool
    
    init(deviceID: String, deviceName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.lastSyncTimestamp = .now
        self.isOnline = true
    }
}
