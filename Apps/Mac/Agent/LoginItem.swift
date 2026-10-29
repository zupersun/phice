import ServiceManagement

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
