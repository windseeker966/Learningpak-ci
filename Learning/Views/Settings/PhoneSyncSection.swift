import SwiftUI

/// 设置页「手机复习」：填手机复习 App 的配对密钥、手机地址，看同步状态（流程见 PhoneSyncSession）
struct PhoneSyncSection: View {
    @Environment(PhoneSyncSession.self) private var phone
    @State private var secretInput = ""
    @State private var secretInvalid = false

    var body: some View {
        @Bindable var phone = phone
        Section {
            if phone.paired {
                Button(phone.busy ? "正在同步…" : "立即同步", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await phone.syncNow() }
                }
                .disabled(phone.busy)
                if let last = phone.lastSuccess {
                    LabeledContent("上次同步", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                if let summary = phone.lastSummary {
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                Button("取消配对", role: .destructive) { phone.unpair() }
            } else {
                HStack {
                    TextField("配对密钥，如 ABCD-EFGH-IJKL-MNOP", text: $secretInput)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onSubmit(pair)
                    Button("配对", action: pair).disabled(secretInput.isEmpty)
                }
                if secretInvalid {
                    Text("密钥是 16 个字母或数字（2–7），在手机复习 App 的设置里能看到").font(.callout).foregroundStyle(.red)
                }
            }
            TextField("手机的 Tailscale 地址（默认 \(PhoneSyncSession.defaultHost)）", text: $phone.manualHost)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
            if let error = phone.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        } header: {
            Text("手机复习")
        } footer: {
            Text("手机上的复习 App 能做今天的选择题、填空题和背单词。iPad 打开时自动和手机同步：把手机上的作答取回来计入复习安排，再把还没做的题推给手机。经 Tailscale 直接连手机：iPad 和手机都要连着 Tailscale，不用在同一个网络。")
        }
    }

    private func pair() {
        secretInvalid = !phone.pair(secretInput)
        if !secretInvalid { secretInput = "" }
    }
}
