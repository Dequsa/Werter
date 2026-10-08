import AppKit

/// Folders macOS guards with a "would like to access files in…" prompt.
enum ProtectedFolder: String, CaseIterable, Identifiable {
    case desktop, documents, downloads

    var id: String { rawValue }

    var name: String { rawValue.capitalized }

    var url: URL {
        let directory: FileManager.SearchPathDirectory = switch self {
        case .desktop: .desktopDirectory
        case .documents: .documentDirectory
        case .downloads: .downloadsDirectory
        }
        return FileManager.default.urls(for: directory, in: .userDomainMask)[0]
    }
}

/// There's no API to ask macOS for a folder's permission state without prompting, so we only
/// probe folders the user has asked for: the first probe shows the system prompt, later ones
/// silently succeed or fail with the remembered answer.
@MainActor
final class Permissions: ObservableObject {
    enum Status { case notRequested, checking, granted, denied }

    private static let requestedKey = "requestedFolders"
    private static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    @Published private(set) var statuses: [ProtectedFolder: Status] = [:]
    @Published private(set) var hasFullDiskAccess = false

    private var requested: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.requestedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.requestedKey) }
    }

    var allGranted: Bool {
        hasFullDiskAccess || ProtectedFolder.allCases.allSatisfy { statuses[$0] == .granted }
    }

    func status(of folder: ProtectedFolder) -> Status {
        hasFullDiskAccess ? .granted : statuses[folder] ?? .notRequested
    }

    func refresh() {
        hasFullDiskAccess = Self.checkFullDiskAccess()
        for folder in ProtectedFolder.allCases where requested.contains(folder.rawValue) {
            probe(folder)
        }
    }

    func request(_ folder: ProtectedFolder) {
        requested.insert(folder.rawValue)
        probe(folder)
    }

    /// One prompt at a time: macOS queues them anyway, and this keeps the rows updating in order.
    func requestAll() {
        Task {
            for folder in ProtectedFolder.allCases where status(of: folder) != .granted {
                requested.insert(folder.rawValue)
                await probeAndWait(folder)
            }
        }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(Self.fullDiskAccessURL)
    }

    private func probe(_ folder: ProtectedFolder) {
        Task { await probeAndWait(folder) }
    }

    private func probeAndWait(_ folder: ProtectedFolder) async {
        statuses[folder] = .checking
        let path = folder.url.path
        // Blocks while the system prompt is on screen, so keep it off the main thread.
        let granted = await Task.detached { (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil }.value
        statuses[folder] = granted ? .granted : .denied
    }

    /// The TCC database is only readable with Full Disk Access; reading it never prompts.
    nonisolated private static func checkFullDiskAccess() -> Bool {
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        try? handle.close()
        return true
    }
}
