import Foundation

enum AudioToolError: LocalizedError {
    case unreadable
    case empty
    case microphoneUnavailable
    case permissionDenied
    case nothingToDelete
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "无法读取这个音频文件。"
        case .empty:
            return "音频是空的。"
        case .microphoneUnavailable:
            return "当前无法使用麦克风。"
        case .permissionDenied:
            return "没有麦克风权限。请在系统设置中允许本应用使用麦克风。"
        case .nothingToDelete:
            return "不能把整段音频都删掉。"
        case .exportFailed:
            return "导出失败。"
        }
    }
}
