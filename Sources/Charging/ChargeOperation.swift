import SwiftUI
import AppKit
import Combine
import Foundation
import QuartzCore

/// Explicit operation ownership prevents a stale background status message from
/// being mistaken for progress on an unrelated card.
enum ChargeOperation: Equatable {
    case enablingLimit
    case adjustingLimit
    case restoringLimit
    case startingFullCharge
    case cancelingFullCharge
    case repairingHelper

    var affectsLimit: Bool {
        switch self {
        case .enablingLimit, .adjustingLimit, .restoringLimit, .repairingHelper: return true
        case .startingFullCharge, .cancelingFullCharge: return false
        }
    }

    var affectsFullCharge: Bool { !affectsLimit }

    var status: AppText {
        switch self {
        case .enablingLimit: return "正在启用…"
        case .adjustingLimit: return "正在设置…"
        case .restoringLimit: return "正在恢复…"
        case .startingFullCharge: return "正在开启…"
        case .cancelingFullCharge: return "正在取消…"
        case .repairingHelper: return "正在修复…"
        }
    }
}
