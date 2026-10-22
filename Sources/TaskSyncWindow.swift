import AppKit
import SwiftUI
import CoreImage

final class TaskSyncWindow {
    static let shared = TaskSyncWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 550),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Noty Sync"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: TaskSyncSettingsView())
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct TaskSyncSettingsView: View {
    @ObservedObject private var sync = TaskSync.shared
    @State private var endpoint = TaskSync.shared.configuration.endpoint
    @State private var token = TaskSync.shared.configuration.token
    @State private var enabled = TaskSync.shared.configuration.enabled
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your tasks, together.").font(.title2.bold())
            Text("Your note text syncs with your phone and gives Desk Pal context. Its own note supplies the Plan screen. Photos stay on this Mac.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Sync site").font(.caption)
                TextField("https://your-noty-site.vercel.app", text: $endpoint)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Sync site address")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Private key").font(.caption)
                SecureField("Your pairing key", text: $token).textFieldStyle(.roundedBorder)
            }
            Toggle("Sync notes and tasks", isOn: $enabled)
            HStack {
                Button("Save settings") {
                    let config = TaskSyncConfiguration(endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                        token: token.trimmingCharacters(in: .whitespacesAndNewlines), enabled: enabled)
                    error = sync.configure(config)
                }.keyboardShortcut(.defaultAction)
                Button("Sync now") { sync.syncNow() }.disabled(!sync.configuration.enabled)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text(sync.status).font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("Sync status: " + sync.status)
            Divider()
            if let link = sync.configuration.pairingURL {
                HStack(alignment: .top, spacing: 16) {
                    if let qr = qrImage(link.absoluteString) {
                        Image(nsImage: qr).interpolation(.none).resizable().frame(width: 112, height: 112)
                            .accessibilityLabel("Scan this QR code with your phone to connect to Noty")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Connect your phone").font(.headline)
                        Text("Scan the code or open your private link on your phone.").font(.caption)
                        Button(copied ? "Link copied" : "Copy private link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.absoluteString, forType: .string)
                            copied = true
                        }
                        Button("Open task page") { NSWorkspace.shared.open(link) }
                    }
                }
                Text("Anyone with this link can access your notes. Keep it private.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Save your sync site and private key to connect your phone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(24).frame(width: 440, height: 550)
    }

    private func qrImage(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 5, y: 5)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
