import Foundation
import SwiftData

/// Persistent local inbox entry. This additive model does not change shipped tables.
@Model
final class AppNotification {
    var uuid: UUID = UUID()
    var title: String = ""
    var message: String = ""
    var timestamp: Date = Date()
    var isRead: Bool = false
    var sourceKey: String = ""

    init(title: String, message: String, sourceKey: String) {
        self.title = title
        self.message = message
        self.sourceKey = sourceKey
    }
}
