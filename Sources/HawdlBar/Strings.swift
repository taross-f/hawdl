import Foundation
import HawdlCore

/// Every string the menu bar UI shows, in both languages.
///
/// See `UILanguage` for why these are compiled in rather than loaded from
/// `.lproj` resource bundles.
enum Strings {
    private static func pick(_ ja: String, _ en: String) -> String {
        UILanguage.current == .japanese ? ja : en
    }

    // MARK: - State line

    static var stateConnecting: String {
        pick("AWDL: 接続中…", "AWDL: connecting…")
    }

    static var stateDaemonMissing: String {
        pick("AWDL: hawdld が未起動", "AWDL: hawdld is not running")
    }

    static func stateError(_ detail: String) -> String {
        pick("AWDL: エラー (\(detail))", "AWDL: error (\(detail))")
    }

    static var stateUnknown: String {
        pick("AWDL: 状態不明", "AWDL: state unknown")
    }

    static var stateNoInterface: String {
        pick("AWDL: awdl0 がありません", "AWDL: no awdl0 interface")
    }

    static func stateHeld(blocked: Int) -> String {
        pick("AWDL: 停止中 (\(blocked) 回ブロック)", "AWDL: held down (\(blocked) blocked)")
    }

    static func stateReleased(blocked: Int) -> String {
        pick("AWDL: 動作中 (\(blocked) 回ブロック)", "AWDL: running (\(blocked) blocked)")
    }

    // MARK: - Daemon line

    static func daemonConnected(version: String) -> String {
        pick("hawdld: 接続済み (v\(version))", "hawdld: connected (v\(version))")
    }

    static var daemonConnecting: String {
        pick("hawdld: 接続中…", "hawdld: connecting…")
    }

    static var daemonMissing: String {
        pick("hawdld: 未起動", "hawdld: not running")
    }

    // MARK: - Actions

    static var hold: String {
        pick("AWDL を停止", "Hold AWDL down")
    }

    static var release: String {
        pick("AWDL を再開", "Release AWDL")
    }

    static var launchAtLogin: String {
        pick("ログイン時に起動", "Launch at login")
    }

    static func copyStartCommand(_ command: String) -> String {
        pick("起動コマンドをコピー (\(command))", "Copy start command (\(command))")
    }

    static var quit: String {
        pick("終了", "Quit")
    }
}
