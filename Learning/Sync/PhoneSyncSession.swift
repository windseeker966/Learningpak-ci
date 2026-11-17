import Foundation
import Observation
import SwiftData

/// 和手机复习 App（learningpack-android）同步：取回手机上的作答（PhoneSyncImport）、推送今天的复习题和单词（PhoneSyncPayload）。
/// App 在前台时：回到前台同步一次，之后每分钟一次；作答、背单词保存后两秒内再同步一次，手机上的题单跟着更新。
/// 经 Tailscale 直接连手机（PhoneLink），两台设备都连着 Tailscale 就行，不用在同一个网络。
/// 配对密钥存钥匙串，手机地址存 UserDefaults（空的用手机的 Tailscale 地址）。协议见 learningpack-android/PROTOCOL.md。由 LearningApp 注入
@MainActor @Observable
final class PhoneSyncSession {
    private static let secretAccount = "phoneSyncSecret"
    /// 以前存的是手填的局域网地址，换了键名，旧值不再用
    private static let manualHostKey = "phoneSync.tailscaleHost"
    /// 手机（xiaomi-14-pro）的 Tailscale 地址
    static let defaultHost = "100.88.249.6"
    private static let lastSuccessKey = "phoneSync.lastSuccess"
    static let interval: TimeInterval = 60

    /// 钥匙串里的配对密钥；没配对（或取消了配对）时为 nil。MacReport 也用它加密
    static var storedSecret: String? {
        guard let s = Keychain.read(account: secretAccount), !s.isEmpty else { return nil }
        return s
    }

    private(set) var paired = Keychain.read(account: secretAccount) != nil
    private(set) var busy = false
    private(set) var error: String?
    private(set) var lastSuccess = UserDefaults.standard.object(forKey: lastSuccessKey) as? Date
    /// 上次同步的结果，显示在设置页
    private(set) var lastSummary: String?
    /// 设置页手填的手机地址；空的用 defaultHost
    var manualHost: String = UserDefaults.standard.string(forKey: PhoneSyncSession.manualHostKey) ?? "" {
        didSet { UserDefaults.standard.set(manualHost.trimmingCharacters(in: .whitespaces), forKey: PhoneSyncSession.manualHostKey) }
    }

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var store: PackStore?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var saveObserver: NSObjectProtocol?
    @ObservationIgnored private var importing = false

    // MARK: - 配对

    /// 填配对密钥（手机复习 App 设置里显示的）；格式不对返回 false
    @discardableResult
    func pair(_ input: String) -> Bool {
        guard let secret = PhoneSyncAuth.normalize(input) else { return false }
        Keychain.save(secret, account: Self.secretAccount)
        paired = true
        error = nil
        if context != nil { syncSoon(delay: 0) }
        return true
    }

    func unpair() {
        Keychain.save("", account: Self.secretAccount)
        paired = false
        lastSummary = nil
    }

    // MARK: - 什么时候同步

    func appBecameActive(in context: ModelContext, store: PackStore) {
        self.context = context
        self.store = store
        #if DEBUG
        // 调试：启动参数 -debugPhoneSecret <配对密钥> -debugPhoneHost 127.0.0.1 直接配对、指定手机地址
        // （模拟器连 adb forward 过来的安卓模拟器）
        let d = UserDefaults.standard
        if let secret = d.string(forKey: "debugPhoneSecret") { pair(secret) }
        if let host = d.string(forKey: "debugPhoneHost") { manualHost = host }
        #endif
        observeSaves()
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    func appEnteredBackground() {
        loop?.cancel()
        loop = nil
        debounce?.cancel()
        debounce = nil
    }

    /// 作答、背单词保存后：复习安排变了，手机上的题单要跟着变
    private func observeSaves() {
        guard saveObserver == nil else { return }
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) {
            [weak self] note in
            let relevant = note.touches([ReviewItem.self, VocabEntry.self, PhraseCard.self])
            MainActor.assumeIsolated {
                guard let self, relevant, !self.importing, self.loop != nil else { return }
                self.syncSoon(delay: 2)
            }
        }
    }

    private func syncSoon(delay: TimeInterval) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    // MARK: - 同步

    /// 立即同步（设置页的按钮）
    func syncNow() async { await sync(force: true) }

    private func sync(force: Bool = false) async {
        guard paired, !busy, let context, let store, !store.packs.isEmpty,
              let secret = Keychain.read(account: Self.secretAccount) else { return }
        busy = true
        defer { busy = false }
        do {
            let done = try await syncPhone(host: host, secret: secret, store: store, in: context)
            error = nil
            lastSuccess = .now
            UserDefaults.standard.set(lastSuccess, forKey: Self.lastSuccessKey)
            let summary = done.summary
            lastSummary = "推送 \(done.built.questionCount) 道题、\(done.built.vocabCount) 个词、\(done.built.phraseCount) 张说法卡"
                + (done.results.isEmpty ? "" : "；取回 \(summary.questions) 道题、\(summary.vocab) 次背单词、\(summary.phrases) 次说法卡、\(summary.passages) 篇短文、\(summary.facts) 轮测速"
                    + (summary.vocabAdded + summary.vocabRemoved == 0 ? "" : "、加入 \(summary.vocabAdded) 个生词、移出 \(summary.vocabRemoved) 个")
                    + (summary.faults == 0 ? "" : "、\(summary.faults) 道标了题目有错")
                    + (summary.marks == 0 ? "" : "、\(summary.marks) 道改了重点或已掌握"))
            if !done.results.isEmpty || done.images > 0 {
                ActivityLog.write("phone_sync", ["pulled": done.results.count, "questions": summary.questions, "vocab": summary.vocab, "phrases": summary.phrases,
                                                 "passages": summary.passages, "skips": summary.skips, "facts": summary.facts,
                                                 "vocab_added": summary.vocabAdded, "vocab_removed": summary.vocabRemoved, "faults": summary.faults,
                                                 "marks": summary.marks,
                                                 "pushed_questions": done.built.questionCount, "images": done.images])
            }
        } catch {
            importing = false
            // 手机没联网、Tailscale 没连上是常态：自动同步时不当成错误显示，只有点了「立即同步」才显示
            if force { self.error = error.localizedDescription }
        }
    }

    private struct Done {
        var results: [[String: Any]]
        var summary: PhoneSyncImport.Summary
        var built: PhoneSyncPayload.Built
        /// 传了几张图片
        var images: Int
    }

    /// 手机的作答结果和学习时间（/pull 的响应）写进数据库
    private func importPulled(_ object: [String: Any], store: PackStore, in context: ModelContext)
        -> (results: [[String: Any]], summary: PhoneSyncImport.Summary) {
        let results = object["results"] as? [[String: Any]] ?? []
        if let study = object["study"] as? [String: Any], PhoneStudyTime.save(study) {
            ActivityLog.write("phone_study_time", study)
        }
        importing = true
        let summary = PhoneSyncImport.apply(results, store: store, in: context)
        importing = false
        return (results, summary)
    }

    /// 要连的手机地址：设置里手填的，空的用手机的 Tailscale 地址
    var host: String {
        let manual = manualHost.trimmingCharacters(in: .whitespaces)
        return manual.isEmpty ? Self.defaultHost : manual
    }

    private func syncPhone(host: String, secret: String, store: PackStore, in context: ModelContext) async throws -> Done {
        // 1. 取回手机上的作答
        let pulled = try await PhoneLink.request(host: host, method: "POST", path: "/pull", body: Data("{}".utf8),
                                                 secret: secret)
        guard let object = try JSONSerialization.jsonObject(with: pulled) as? [String: Any] else {
            throw PhoneLink.LinkError.badResponse("pull")
        }
        let (results, summary) = importPulled(object, store: store, in: context)
        // 2. 确认取回的、推送今天的题单和单词
        let built = PhoneSyncPayload.build(ack: results.compactMap { $0["id"] as? String }, store: store, in: context)
        let body = try JSONSerialization.data(withJSONObject: built.json)
        let pushed = try await PhoneLink.request(host: host, method: "POST", path: "/push", body: body, secret: secret)
        let need = (try JSONSerialization.jsonObject(with: pushed) as? [String: Any])?["needImages"] as? [String] ?? []
        // 3. 手机还没有的图片
        for sha in need {
            guard let url = built.images[sha], let data = try? Data(contentsOf: url) else { continue }
            _ = try await PhoneLink.request(host: host, method: "POST", path: "/image?sha=\(sha)", body: data,
                                            secret: secret, timeout: 60)
        }
        return Done(results: results, summary: summary, built: built, images: need.count)
    }
}
