import Foundation
import UIKit

/// 把 iPad 上今天的学习时间（IPadStudyTime）经 Tailscale 发给 Mac，给 Mac 上的「上午先学后折腾」提醒
/// （time-tracker-macos 的 morning_guard.py）用：`POST /study`，签名同和手机同步（PhoneSyncAuth，用手机复习的配对密钥），
/// Mac 校验后回签名的 `{"ok":true}`。协议见 learningpack-android/PROTOCOL.md 的「给 Mac 的学习时间」。
/// Mac 的地址默认是它的 Tailscale 地址，UserDefaults `macReport.host` 能改；没配对手机复习时不发。
/// 何时发见 MacStudyReport；StateCheckSession 每次记前台时间后调用（前台约 30 秒一次，进后台时一次）。
/// 发失败下次再试；错误只在和上次不同时写操作日志 mac_report_error，避免每 30 秒记一条
enum MacReport {
    static let defaultHost = "100.99.202.74"
    static let hostKey = "macReport.host"
    static let port: UInt16 = 47323

    private static var last: MacStudyReport.Sent?
    private static var sending = false
    private static var lastError: String?

    static var host: String {
        let saved = UserDefaults.standard.string(forKey: hostKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return saved.isEmpty ? defaultHost : saved
    }

    static func update(active: Bool, now: Date = .now) {
        guard !sending, let secret = PhoneSyncSession.storedSecret else { return }
        let day = StudyPacePolicy.dayKey(now)
        let today = IPadStudyTime.today(day)
        let minutes = Int(today.seconds / 60)
        guard MacStudyReport.due(last: last, day: day, minutes: minutes, starts: today.starts, active: active, now: now) else { return }
        let sent = MacStudyReport.Sent(day: day, minutes: minutes, starts: today.starts, active: active, at: now)
        guard let body = try? JSONSerialization.data(withJSONObject: MacStudyReport.body(
            day: day, seconds: today.seconds, starts: today.starts, active: active, now: now)) else { return }
        sending = true
        // 进后台时那一次：申请一点后台时间把它发完
        let task = active ? UIBackgroundTaskIdentifier.invalid : UIApplication.shared.beginBackgroundTask(withName: "MacReport")
        let host = host
        Task {
            do {
                _ = try await PhoneLink.request(host: host, port: port, method: "POST", path: "/study", body: body,
                                                secret: secret, timeout: 8)
                last = sent
                lastError = nil
            } catch {
                let text = error.localizedDescription
                if text != lastError { ActivityLog.write("mac_report_error", ["error": text, "host": host]) }
                lastError = text
            }
            sending = false
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }
}
