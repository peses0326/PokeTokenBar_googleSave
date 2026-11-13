import AppKit
import SwiftUI

@MainActor
struct GoogleSyncSettingsView: View {
    @Bindable var sync: GoogleCloudSync
    let companion: CompanionStore
    let usage: UsageStore
    private var l: L { companion.l }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(l.gsTitle, systemImage: "icloud")
                .font(.headline)
            Text(l.gsIntro)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if sync.enabled {
                Text(sync.email).font(.callout).textSelection(.enabled)
                if let url = sync.driveFolderURL {
                    Button(l.gsOpenFolder) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.plain).foregroundStyle(.blue).font(.caption)
                }
                if sync.status == "synced", let date = sync.lastSync {
                    Text(l.gsLastSynced(date.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !sync.remoteDevices.isEmpty {
                    let today = LocalUsageReader.todayKey()
                    Text(l.gsOtherDevicesToday(sync.remoteDevices
                        .map { "\($0.deviceName) \(TokenFormatter.compact($0.tokens(on: today)))" }
                        .joined(separator: " · ")))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if ["empty", "choose", "conflict"].contains(sync.status) {
                    Text(sync.status == "empty"
                         ? l.gsEmpty
                         : l.gsChoose)
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button(l.gsContinueLocal) { resolve("local", revision: nil) }
                    ForEach(Array(sync.heads.enumerated()), id: \.element.id) { index, head in
                        VStack(alignment: .leading, spacing: 3) {
                            Button(l.gsContinueRemote(index + 1)) {
                                resolve("remote", revision: head.revision)
                            }
                            Text([head.label, head.savedAt].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button(l.gsSyncNow) {
                        Task { await sync.synchronize(companion: companion, usage: usage) }
                    }
                    Spacer()
                    Button(l.gsDisconnect) {
                        Task { await sync.disconnect(); await usage.refresh() }
                    }
                }
            } else {
                Button(l.gsSignIn) { signIn() }
                    .disabled(!sync.loginConfigured)
                Text(l.gsSignInHint)
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !sync.loginConfigured {
                    Text(l.gsClientMissing)
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            if sync.busy { ProgressView(l.gsConnecting).controlSize(.small) }
            if let message = sync.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if sync.enabled && sync.loginConfigured {
                    Button(l.gsSignInAgain) { signIn() }
                }
            }
            Text(l.gsAutoSyncNote)
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .disabled(sync.busy)
    }

    private func signIn() {
        Task {
            await sync.connect()
            if sync.enabled && sync.errorMessage == nil { await sync.synchronize(companion: companion, usage: usage) }
        }
    }

    private func resolve(_ choice: String, revision: String?) {
        let alert = NSAlert()
        alert.messageText = l.gsConfirmTitle
        alert.informativeText = l.gsConfirmBody
        alert.addButton(withTitle: l.gsCancel)
        alert.addButton(withTitle: l.gsContinue)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task { await sync.synchronize(companion: companion, usage: usage, resolution: choice, revision: revision) }
    }
}
