import AppKit
import SwiftUI

@MainActor
final class SetupWindowController {
    private static let completedKey = "didCompleteSetup"

    private let permissions = Permissions()
    private var window: NSWindow?
    private var activationObserver: NSObjectProtocol?

    static var hasCompletedSetup: Bool { UserDefaults.standard.bool(forKey: completedKey) }

    func show() {
        permissions.refresh()
        if window == nil {
            let view = SetupView(permissions: permissions) { [weak self] in self?.finish() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "File Converter Setup"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
            // Pick up Full Disk Access after the user flips it in System Settings and comes back.
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window?.isVisible == true else { return }
                    self.permissions.refresh()
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        window?.close()
    }
}

struct SetupView: View {
    @ObservedObject var permissions: Permissions
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to File Converter")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Hold **⌥ Option** while dragging PNG, JPEG or HEIC files and the wheel appears. Drop on a format to convert — the copy is saved next to the original.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Folder access").font(.headline)
                Text("macOS asks before an app can save into these folders. Allow them now so you're not interrupted mid-drag.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    ForEach(ProtectedFolder.allCases) { folder in
                        folderRow(folder)
                        Divider().padding(.leading, 44)
                    }
                    fullDiskAccessRow
                }
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            }

            HStack {
                if !permissions.allGranted {
                    Button("Allow All Folders") { permissions.requestAll() }
                }
                Spacer()
                Button(permissions.allGranted ? "Done" : "Skip for Now", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .padding(.top, 8)
        .frame(width: 460)
    }

    private func folderRow(_ folder: ProtectedFolder) -> some View {
        row(icon: "folder.fill", title: folder.name, subtitle: nil) {
            switch permissions.status(of: folder) {
            case .notRequested: Button("Allow") { permissions.request(folder) }
            case .checking: ProgressView().controlSize(.small)
            case .granted: grantedLabel
            case .denied:
                Button("Open Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
                }
            }
        }
    }

    private var fullDiskAccessRow: some View {
        row(icon: "externaldrive.fill", title: "Full Disk Access",
            subtitle: "Optional — covers every folder, iCloud Drive and external drives.") {
            if permissions.hasFullDiskAccess {
                grantedLabel
            } else {
                Button("Open Settings…") { permissions.openFullDiskAccessSettings() }
            }
        }
    }

    private var grantedLabel: some View {
        Label("Allowed", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .labelStyle(.titleAndIcon)
    }

    private func row(icon: String, title: String, subtitle: String?,
                     @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}
