import Cocoa
import CryptoKit

let fm = FileManager.default
let capCutBundleID = "com.lemon.lvoverseas"
let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
let projectPage = URL(string: "https://github.com/enrik891/capcut-transfer")!

// MARK: - Language

/// Italian when the Mac's first preferred language is Italian, English otherwise.
let italian: Bool = {
    if let forced = ProcessInfo.processInfo.environment["CAPCUT_TRANSFER_LANG"] { return forced == "it" }
    return (Locale.preferredLanguages.first ?? "en").hasPrefix("it")
}()
func t(_ it: String, _ en: String) -> String { italian ? it : en }

// MARK: - Utility

struct Cancelled: Error {}
func failure(_ message: String) -> NSError { NSError(domain: "CapCut Transfer", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
func readJSON(_ u: URL) throws -> Any {
    do { return try JSONSerialization.jsonObject(with: Data(contentsOf: u), options: [.fragmentsAllowed]) }
    catch { throw failure(t("Impossibile leggere il file di progetto:", "Can't read the project file:") + "\n\(u.path)\n\n\(error.localizedDescription)") }
}
func writeJSON(_ value: Any, _ u: URL) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]).write(to: u, options: .atomic) }
func transform(_ x: Any, _ f: (String) -> String) -> Any {
    if let s = x as? String { return f(s) }
    if let a = x as? [Any] { return a.map { transform($0, f) } }
    if let d = x as? [String: Any] { return d.mapValues { transform($0, f) } }
    return x
}
func jsonFiles(_ root: URL) -> [URL] {
    guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
    return e.compactMap { $0 as? URL }.filter { u in
        guard u.lastPathComponent.hasSuffix(".json") || u.lastPathComponent.hasSuffix(".json.bak") else { return false }
        // CapCut creates empty auxiliary JSON files. Preserve them in the copy without parsing.
        let required = ["draft_meta_info.json", "draft_info.json", "draft_content.json"].contains(u.lastPathComponent)
        let size = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return required || size != 0
    }
}
let symlinkMessage = t("Il pacchetto contiene collegamenti simbolici: operazione interrotta.", "The package contains symbolic links: operation stopped.")
func checkLinks(_ root: URL) throws {
    guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
    for case let u as URL in e { if try u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw failure(symlinkMessage) } }
}
func fileSize(_ u: URL) -> Int64 { Int64((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
func treeSize(_ root: URL) -> (bytes: Int64, files: Int) {
    var dir: ObjCBool = false
    guard fm.fileExists(atPath: root.path, isDirectory: &dir) else { return (0, 0) }
    guard dir.boolValue else { return (fileSize(root), 1) }
    guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return (0, 0) }
    var total: Int64 = 0, count = 0
    for case let u as URL in e {
        let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0); count += 1 }
    }
    return (total, count)
}
func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
func freeSpace(at u: URL) -> Int64? {
    var probe = u
    while !fm.fileExists(atPath: probe.path) && probe.path != "/" { probe = probe.deletingLastPathComponent() }
    return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
}
func installedCapCutVersion() -> String? {
    guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: capCutBundleID) else { return nil }
    return Bundle(url: u)?.infoDictionary?["CFBundleShortVersionString"] as? String
}
func capCutIsRunning(_ bundleIDs: [String]) -> Bool { bundleIDs.contains { $0 == capCutBundleID } }
func runningCapCut() -> [NSRunningApplication] { NSRunningApplication.runningApplications(withBundleIdentifier: capCutBundleID) }
func plural(_ n: Int, _ itOne: String, _ itMany: String, _ enOne: String, _ enMany: String) -> String {
    "\(n) " + (n == 1 ? t(itOne, enOne) : t(itMany, enMany))
}

// MARK: - Progress and copy

/// Byte-level progress shared between the worker thread and the UI. Cancellation is checked between 4 MB chunks.
final class Job {
    private let lock = NSLock()
    private var _cancelled = false, _done: Int64 = 0, _total: Int64 = 0, _item = ""
    private var lastNotify = Date.distantPast
    let started = Date()
    var onChange: ((Job) -> Void)?
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var snapshot: (done: Int64, total: Int64, item: String) { lock.lock(); defer { lock.unlock() }; return (_done, _total, _item) }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    func addTotal(_ n: Int64) { lock.lock(); _total += n; lock.unlock(); notify(force: true) }
    func step(_ item: String) { lock.lock(); _item = item; lock.unlock(); notify(force: true) }
    func add(_ n: Int64, _ item: String) { lock.lock(); _done += n; _item = item; lock.unlock(); notify(force: false) }
    func check() throws { if cancelled { throw Cancelled() } }
    private func notify(force: Bool) {
        let now = Date()
        lock.lock(); let due = force || now.timeIntervalSince(lastNotify) > 0.1; if due { lastNotify = now }; lock.unlock()
        if due { onChange?(self) }
    }
}

func sha256Hex(_ d: SHA256.Digest) -> String { d.map { String(format: "%02x", $0) }.joined() }

/// Copies one file in chunks, reporting progress and returning its SHA-256.
@discardableResult
func copyFile(_ s: URL, _ d: URL, _ job: Job?) throws -> String {
    guard let input = try? FileHandle(forReadingFrom: s) else { throw failure(t("Impossibile leggere il file:", "Can't read the file:") + "\n\(s.path)") }
    defer { try? input.close() }
    guard fm.createFile(atPath: d.path, contents: nil), let output = try? FileHandle(forWritingTo: d) else { throw failure(t("Impossibile scrivere il file:", "Can't write the file:") + "\n\(d.path)") }
    defer { try? output.close() }
    var hasher = SHA256()
    while true {
        try job?.check()
        let chunk: Data = try autoreleasepool { try input.read(upToCount: 4 << 20) ?? Data() }
        if chunk.isEmpty { break }
        try output.write(contentsOf: chunk)
        hasher.update(data: chunk)
        job?.add(Int64(chunk.count), s.lastPathComponent)
    }
    if let m = try? fm.attributesOfItem(atPath: s.path)[.modificationDate] { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: d.path) }
    return sha256Hex(hasher.finalize())
}

/// Recursively copies a file or folder. Checksums are collected with keys relative to the package root (e.g. "Media/3-clip.mov").
func copyTree(_ s: URL, _ d: URL, _ rel: String, _ job: Job?, _ sums: inout [String: String]) throws {
    let v = try s.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    if v.isSymbolicLink == true { throw failure(symlinkMessage) }
    if v.isDirectory == true {
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        for c in try fm.contentsOfDirectory(at: s, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            try copyTree(c, d.appendingPathComponent(c.lastPathComponent), rel + "/" + c.lastPathComponent, job, &sums)
        }
    } else {
        sums[rel] = try copyFile(s, d, job)
    }
}

/// Runs /usr/bin/ditto, killing it if the job is cancelled.
func ditto(_ args: [String], _ job: Job?) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = args
    try p.run()
    while p.isRunning {
        if job?.cancelled == true { p.terminate(); p.waitUntilExit(); throw Cancelled() }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard p.terminationStatus == 0 else { throw failure(t("Compressione o estrazione ZIP non riuscita.", "ZIP compression or extraction failed.")) }
}

// MARK: - Engine

struct ProjectScan {
    var refs: [String]
    var missing: [String]
    var bytes: Int64
}

struct PackageInfo {
    var url: URL
    var name: String
    var capCutVersion: String?
    var sourceMac: String?
    var createdAt: Date?
    var bytes: Int64
    var files: Int
    var hasChecksums: Bool
}

struct Engine {
    static let mediaExtensions: Set<String> = ["mp4","mov","m4v","avi","mkv","mp3","wav","aac","m4a","flac","png","jpg","jpeg","webp","heic","gif","ttf","otf","srt","aif","aiff"]

    /// Finds every external file the project references and which of them are missing. Does not copy anything.
    static func analyze(_ project: URL) throws -> ProjectScan {
        let files = jsonFiles(project)
        guard fm.fileExists(atPath: project.appendingPathComponent("draft_meta_info.json").path) else { throw failure(t("Questa cartella non è un progetto CapCut.", "This folder is not a CapCut project.")) }
        guard files.contains(where: { ["draft_info.json", "draft_content.json"].contains($0.lastPathComponent) }) else { throw failure(t("File principale del progetto non trovato.", "The project's main file is missing.")) }
        var refs = Set<String>()
        for file in files {
            let data = try readJSON(file)
            _ = transform(data) { s in
                let p = s.hasPrefix("file://") ? (URL(string: s)?.path ?? s) : s
                if p.hasPrefix("/"), !p.hasPrefix(project.path + "/"), p != project.path {
                    var dir: ObjCBool = false
                    let exists = fm.fileExists(atPath: p, isDirectory: &dir)
                    let ext = URL(fileURLWithPath: p).pathExtension.lowercased()
                    if (exists && !dir.boolValue) || mediaExtensions.contains(ext) { refs.insert(p) }
                }
                return s
            }
        }
        let sorted = refs.sorted()
        let missing = sorted.filter { !fm.fileExists(atPath: $0) }
        let total = treeSize(project).bytes + sorted.reduce(Int64(0)) { $0 + fileSize(URL(fileURLWithPath: $1)) }
        return ProjectScan(refs: sorted, missing: missing, bytes: total)
    }

    static func missingMessage(_ missing: [String]) -> String {
        let shown = missing.prefix(12).joined(separator: "\n")
        let more = missing.count > 12 ? t("\n…e altri \(missing.count - 12)", "\n…and \(missing.count - 12) more") : ""
        let head = missing.count == 1
            ? t("Manca 1 file. Scaricalo o ricollegalo in CapCut, poi riprova.", "1 file is missing. Download or relink it in CapCut, then try again.")
            : t("Mancano \(missing.count) file. Scaricali o ricollegali in CapCut, poi riprova.", "\(missing.count) files are missing. Download or relink them in CapCut, then try again.")
        return head + "\n\n" + shown + more
    }
    static let exists = t("Esiste già un pacchetto con questo nome. Scegli un altro nome.", "A package with this name already exists. Choose another name.")

    static func export(_ project: URL, to destination: URL, scan given: ProjectScan? = nil, job: Job? = nil) throws {
        guard !destination.standardizedFileURL.path.hasPrefix(project.standardizedFileURL.path + "/") else { throw failure(t("Salva il pacchetto fuori dalla cartella del progetto.", "Save the package outside the project folder.")) }
        let scan = try given ?? analyze(project)
        if !scan.missing.isEmpty { throw failure(missingMessage(scan.missing)) }
        guard !fm.fileExists(atPath: destination.path) else { throw failure(exists) }
        try checkLinks(project)
        job?.addTotal(scan.bytes)
        // Build the package next to its destination so the final step is a rename, not a second copy.
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).partial-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stage) }
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        var sums = [String: String]()
        try copyTree(project, stage.appendingPathComponent("Project"), "Project", job, &sums)
        let media = stage.appendingPathComponent("Media")
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        var mapping = [String: String]()
        for (i, p) in scan.refs.enumerated() {
            let relative = "Media/\(i)-" + URL(fileURLWithPath: p).lastPathComponent
            sums[relative] = try copyFile(URL(fileURLWithPath: p), stage.appendingPathComponent(relative), job)
            mapping[p] = relative
        }
        let meta = (try? readJSON(project.appendingPathComponent("draft_meta_info.json"))) as? [String: Any]
        var manifest: [String: Any] = [
            "format": 1, "originalProject": project.path, "mapping": mapping,
            "checksums": sums, "appVersion": appVersion,
            "projectName": meta?["draft_name"] as? String ?? project.lastPathComponent,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "sourceMac": Host.current().localizedName ?? "Mac",
        ]
        if let v = installedCapCutVersion() { manifest["capcutVersion"] = v }
        try writeJSON(manifest, stage.appendingPathComponent("manifest.json"))
        try job?.check()
        guard !fm.fileExists(atPath: destination.path) else { throw failure(exists) }
        try fm.moveItem(at: stage, to: destination)
    }

    /// Compresses a package into "<name>.capcuttransfer.zip" next to it, without recompressing the media.
    static func zip(_ package: URL, job: Job?) throws -> URL {
        let out = package.appendingPathExtension("zip")
        guard !fm.fileExists(atPath: out.path) else { throw failure(t("Esiste già \(out.lastPathComponent).", "\(out.lastPathComponent) already exists.")) }
        let partial = package.deletingLastPathComponent().appendingPathComponent(".\(out.lastPathComponent).partial-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: partial) }
        job?.step(t("Creo \(out.lastPathComponent)", "Creating \(out.lastPathComponent)"))
        // Video and audio are already compressed: store them as they are so zipping takes seconds, not minutes.
        try ditto(["-c", "-k", "--keepParent", "--zlibCompressionLevel", "0", package.path, partial.path], job)
        try fm.moveItem(at: partial, to: out)
        return out
    }

    static func manifest(_ package: URL) throws -> [String: Any] {
        guard fm.fileExists(atPath: package.appendingPathComponent("manifest.json").path),
              let m = try readJSON(package.appendingPathComponent("manifest.json")) as? [String: Any], m["format"] as? Int == 1 else { throw failure(t("Questo non è un pacchetto CapCut Transfer valido.", "This is not a valid CapCut Transfer package.")) }
        return m
    }

    static func inspect(_ package: URL) throws -> PackageInfo {
        let m = try manifest(package)
        let size = treeSize(package)
        let name = m["projectName"] as? String
            ?? ((try? readJSON(package.appendingPathComponent("Project/draft_meta_info.json"))) as? [String: Any])?["draft_name"] as? String
            ?? package.deletingPathExtension().lastPathComponent
        return PackageInfo(url: package, name: name, capCutVersion: m["capcutVersion"] as? String, sourceMac: m["sourceMac"] as? String,
                           createdAt: (m["createdAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
                           bytes: size.bytes, files: size.files, hasChecksums: m["checksums"] is [String: String])
    }

    static func restore(_ package: URL, into root: URL, job: Job? = nil) throws -> URL {
        try checkLinks(package)
        let manifest = try manifest(package)
        let invalid = t("Il pacchetto è incompleto o non valido.", "The package is incomplete or invalid.")
        let noProject = t("Progetto mancante nel pacchetto.", "The package doesn't contain a project.")
        guard let original = manifest["originalProject"] as? String, original.hasPrefix("/"),
              let mapping = manifest["mapping"] as? [String: String] else { throw failure(invalid) }
        for relative in mapping.values {
            guard relative.hasPrefix("Media/"), !relative.split(separator: "/").contains(".."), fm.fileExists(atPath: package.appendingPathComponent(relative).path) else { throw failure(invalid) }
        }
        let source = package.appendingPathComponent("Project")
        guard fm.fileExists(atPath: source.appendingPathComponent("draft_meta_info.json").path) else { throw failure(noProject) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let mediaSource = package.appendingPathComponent("Media")
        let needed = treeSize(source).bytes + treeSize(mediaSource).bytes
        if let free = freeSpace(at: root), free < needed + 200_000_000 {
            throw failure(t("Spazio insufficiente: servono \(bytes(needed)), liberi \(bytes(free)).", "Not enough space: \(bytes(needed)) needed, \(bytes(free)) available."))
        }
        job?.addTotal(needed)
        let token = UUID().uuidString
        let target = root.appendingPathComponent("Importato-" + token)
        let stage = root.appendingPathComponent(".transfer-" + token)
        defer { try? fm.removeItem(at: stage) }
        let assetFolder = "TransferMedia-" + token
        var sums = [String: String]()
        try copyTree(source, stage, "Project", job, &sums)
        if fm.fileExists(atPath: mediaSource.path) { try copyTree(mediaSource, stage.appendingPathComponent(assetFolder), "Media", job, &sums) }
        else { try fm.createDirectory(at: stage.appendingPathComponent(assetFolder), withIntermediateDirectories: true) }
        // Packages from 0.2+ carry checksums: compare them with what was actually read during the copy.
        if let expected = manifest["checksums"] as? [String: String] {
            job?.step(t("Verifica integrità", "Checking integrity"))
            let damaged = expected.filter { sums[$0.key] != nil && sums[$0.key] != $0.value }.map { $0.key }.sorted()
            let absent = expected.keys.filter { sums[$0] == nil }.sorted()
            if !damaged.isEmpty {
                throw failure(t("\(damaged.count) file risultano danneggiati durante il trasferimento. Copia di nuovo il pacchetto dal primo Mac.",
                                "\(damaged.count) file(s) were damaged during the transfer. Copy the package again from the first Mac.") + "\n\n" + damaged.prefix(8).joined(separator: "\n"))
            }
            if !absent.isEmpty {
                throw failure(t("Il pacchetto è incompleto: mancano \(absent.count) file. Copia di nuovo il pacchetto dal primo Mac.",
                                "The package is incomplete: \(absent.count) file(s) missing. Copy the package again from the first Mac.") + "\n\n" + absent.prefix(8).joined(separator: "\n"))
            }
        }
        try job?.check()
        job?.step(t("Aggiorno i percorsi del progetto", "Updating project paths"))
        for file in jsonFiles(stage) {
            let data = try readJSON(file)
            let fixed = transform(data) { s in
                let isURL = s.hasPrefix("file://")
                let p = isURL ? (URL(string: s)?.path ?? s) : s
                var replacement: String? = nil
                if let relative = mapping[p] { replacement = target.appendingPathComponent(assetFolder).appendingPathComponent(String(relative.dropFirst(6))).path }
                else if p == original { replacement = target.path }
                else if p.hasPrefix(original + "/") { replacement = target.path + p.dropFirst(original.count) }
                else if p == URL(fileURLWithPath: original).deletingLastPathComponent().path { replacement = root.path }
                guard let r = replacement else { return s }
                return isURL ? URL(fileURLWithPath: r).absoluteString : r
            }
            try writeJSON(fixed, file)
        }
        let metaURL = stage.appendingPathComponent("draft_meta_info.json")
        guard var meta = try readJSON(metaURL) as? [String: Any] else { throw failure(noProject) }
        let oldID = meta["draft_id"] as? String ?? ""
        for file in jsonFiles(stage) {
            let data = try readJSON(file)
            try writeJSON(transform(data) { $0 == oldID && !oldID.isEmpty ? token : $0 }, file)
        }
        guard let reread = try readJSON(metaURL) as? [String: Any] else { throw failure(noProject) }
        meta = reread
        meta["draft_fold_path"] = target.path; meta["draft_root_path"] = root.path
        meta["draft_name"] = (meta["draft_name"] as? String ?? t("Progetto", "Project")) + t(" (importato)", " (imported)")
        try writeJSON(meta, metaURL)
        let indexURL = root.appendingPathComponent("root_meta_info.json")
        var index: [String: Any] = ["all_draft_store": [[String: Any]](), "draft_ids": 0, "root_path": root.path]
        if fm.fileExists(atPath: indexURL.path) {
            guard let existing = try readJSON(indexURL) as? [String: Any], existing["all_draft_store"] is [[String: Any]] else {
                throw failure(t("Indice CapCut non riconosciuto. Nessun progetto è stato importato.", "CapCut's project index wasn't recognised. Nothing was imported."))
            }
            index = existing
            try fm.copyItem(at: indexURL, to: root.appendingPathComponent("root_meta_info.backup-\(token).json"))
        }
        var entries = index["all_draft_store"] as? [[String: Any]] ?? []
        entries.insert(meta, at: 0); index["all_draft_store"] = entries
        if let ids = index["draft_ids"] as? [String] { index["draft_ids"] = ids + [token] }
        else if let count = index["draft_ids"] as? Int { index["draft_ids"] = count + 1 }
        try job?.check()
        try fm.moveItem(at: stage, to: target)
        do { try writeJSON(index, indexURL) } catch { try? fm.removeItem(at: target); throw error }
        return target
    }

    /// Extracts a zipped package into a temporary folder and returns the package inside it.
    static func unzip(_ zip: URL, job: Job?) throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("CapCutTransfer-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        job?.step(t("Estraggo \(zip.lastPathComponent)", "Extracting \(zip.lastPathComponent)"))
        do { try ditto(["-x", "-k", zip.path, dir.path], job) } catch { try? fm.removeItem(at: dir); throw error }
        if fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) { return dir }
        let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        if let pkg = children.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }) { return pkg }
        try? fm.removeItem(at: dir)
        throw failure(t("Lo ZIP non contiene un pacchetto .capcuttransfer.", "The ZIP doesn't contain a .capcuttransfer package."))
    }
}

// MARK: - Project list model

final class ProjectItem {
    let url: URL
    var name: String
    var duration: Double
    var modified: Date
    var cover: NSImage?
    var scan: ProjectScan?
    var scanError: String?
    init(url: URL, name: String, duration: Double, modified: Date, cover: NSImage?) {
        self.url = url; self.name = name; self.duration = duration; self.modified = modified; self.cover = cover
    }
    var ready: Bool { scan != nil && scan!.missing.isEmpty && scanError == nil }

    static func load(_ folder: URL) -> ProjectItem? {
        let metaURL = folder.appendingPathComponent("draft_meta_info.json")
        guard let meta = (try? readJSON(metaURL)) as? [String: Any] else { return nil }
        if meta["draft_is_invisible"] as? Bool == true { return nil }
        let micro = { (k: String) -> Double in (meta[k] as? NSNumber)?.doubleValue ?? Double(meta[k] as? String ?? "") ?? 0 }
        var modified = Date(timeIntervalSince1970: micro("tm_draft_modified") / 1_000_000)
        if micro("tm_draft_modified") == 0 { modified = (try? metaURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast }
        let coverName = meta["draft_cover"] as? String ?? "draft_cover.jpg"
        let cover = NSImage(contentsOf: folder.appendingPathComponent(coverName.isEmpty ? "draft_cover.jpg" : coverName))
        return ProjectItem(url: folder, name: (meta["draft_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folder.lastPathComponent,
                           duration: micro("tm_duration") / 1_000_000, modified: modified, cover: cover)
    }
}

func durationText(_ s: Double) -> String {
    let t = Int(s.rounded()); return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

// MARK: - Views

final class ProjectCell: NSTableCellView {
    let cover = NSImageView(), title = NSTextField(labelWithString: ""), detail = NSTextField(labelWithString: ""), badge = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        cover.imageScaling = .scaleProportionallyUpOrDown; cover.wantsLayer = true; cover.layer?.cornerRadius = 4; cover.layer?.masksToBounds = true
        cover.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        title.font = .systemFont(ofSize: 13, weight: .semibold); title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11.5); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingTail
        badge.font = .systemFont(ofSize: 11.5, weight: .medium); badge.alignment = .right
        for v in [cover, title, detail, badge] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            cover.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), cover.centerYAnchor.constraint(equalTo: centerYAnchor),
            cover.widthAnchor.constraint(equalToConstant: 80), cover.heightAnchor.constraint(equalToConstant: 45),
            title.leadingAnchor.constraint(equalTo: cover.trailingAnchor, constant: 12), title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor), detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -12),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ p: ProjectItem, _ dates: DateFormatter) {
        cover.image = p.cover; title.stringValue = p.name
        var parts = [durationText(p.duration) + " min"]
        if let s = p.scan { parts.append(bytes(s.bytes)) }
        parts.append(t("modificato ", "modified ") + dates.string(from: p.modified))
        if p.name != p.url.lastPathComponent { parts.append(t("cartella ", "folder ") + p.url.lastPathComponent) }
        detail.stringValue = parts.joined(separator: " · ")
        if let e = p.scanError { badge.stringValue = t("Non leggibile", "Unreadable"); badge.textColor = .systemRed; badge.toolTip = e }
        else if let s = p.scan {
            if s.missing.isEmpty {
                badge.stringValue = t("✓ Pronto", "✓ Ready"); badge.textColor = .systemGreen
                badge.toolTip = plural(s.refs.count, "file multimediale trovato", "file multimediali trovati", "media file found", "media files found")
            } else {
                badge.stringValue = plural(s.missing.count, "file mancante", "file mancanti", "missing file", "missing files")
                badge.textColor = .systemRed; badge.toolTip = s.missing.prefix(10).joined(separator: "\n")
            }
        } else { badge.stringValue = t("Controllo…", "Checking…"); badge.textColor = .tertiaryLabelColor; badge.toolTip = nil }
    }
}

/// Dashed drop area that accepts .capcuttransfer packages and .zip archives.
final class DropView: NSView {
    var onDrop: ((URL) -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    static func accepts(_ u: URL) -> Bool { ["capcuttransfer", "zip"].contains(u.pathExtension.lowercased()) || fm.fileExists(atPath: u.appendingPathComponent("manifest.json").path) }
    private func url(_ info: NSDraggingInfo) -> URL? {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first(where: DropView.accepts)
    }
    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation { highlighted = url(info) != nil; return highlighted ? .copy : [] }
    override func draggingExited(_ info: NSDraggingInfo?) { highlighted = false }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool { highlighted = false; guard let u = url(info) else { return false }; onDrop?(u); return true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 12, yRadius: 12)
        path.lineWidth = 2; path.setLineDash([7, 5], count: 2, phase: 0)
        (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke(); path.stroke()
        if highlighted { NSColor.controlAccentColor.withAlphaComponent(0.08).setFill(); path.fill() }
    }
}

func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: s); l.font = .systemFont(ofSize: size, weight: weight); l.textColor = color; l.isSelectable = false; return l
}
func hstack(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
    let s = NSStackView(views: views); s.orientation = .horizontal; s.spacing = spacing; s.alignment = .centerY; return s
}
func spacer() -> NSView { let v = NSView(); v.setContentHuggingPriority(.init(1), for: .horizontal); return v }

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var window: NSWindow!
    var root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Movies/CapCut/User Data/Projects/com.lveditor.draft")
    var projects = [ProjectItem](), shown = [ProjectItem]()
    var scanGeneration = 0
    let dates: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f }()

    // Shared chrome
    let modeControl = NSSegmentedControl(labels: [t("Esporta", "Export"), t("Importa", "Import")], trackingMode: .selectOne, target: nil, action: nil)
    let tabs = NSTabView()
    let capCutDot = NSTextField(labelWithString: "●"), capCutLabel = NSTextField(labelWithString: "")
    let quitCapCut = NSButton(title: t("Chiudi CapCut", "Quit CapCut"), target: nil, action: nil)
    let progress = NSProgressIndicator(), progressLabel = NSTextField(labelWithString: "")
    let cancelButton = NSButton(title: t("Annulla", "Cancel"), target: nil, action: nil)
    var progressRow: NSStackView!
    let status = NSTextField(wrappingLabelWithString: "")
    let followUp = NSButton(title: "", target: nil, action: nil)
    var followUpAction: (() -> Void)?
    var job: Job?

    // Export
    let search = NSSearchField(), table = NSTableView()
    let summary = NSTextField(wrappingLabelWithString: "")
    let zipOption = NSButton(checkboxWithTitle: t("Crea anche un .zip per l'invio online", "Also create a .zip for sending online"), target: nil, action: nil)
    let exportButton = NSButton(title: t("Esporta…", "Export…"), target: nil, action: nil)

    // Import
    let drop = DropView()
    let packageInfo = NSTextField(wrappingLabelWithString: "")
    let destinationLabel = NSTextField(labelWithString: "")
    let importButton = NSButton(title: t("Importa", "Import"), target: nil, action: nil)
    var package: PackageInfo?
    var tempFolders = [URL]()
    var pendingOpen: URL?

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu(); buildWindow()
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshCapCut() }
        }
        refreshCapCut(); updateDestination(); updateImport(); setStatus(t("Pronto. I progetti originali non vengono mai modificati.", "Ready. Your original projects are never modified."))
        reloadProjects()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if let u = pendingOpen { pendingOpen = nil; openPackage(u) }
        // Development aid: CAPCUT_TRANSFER_SNAPSHOT=/path/prefix renders both tabs to PNG and quits.
        if let prefix = ProcessInfo.processInfo.environment["CAPCUT_TRANSFER_SNAPSHOT"] {
            NSApp.appearance = NSAppearance(named: .aqua)
            if let pkg = ProcessInfo.processInfo.environment["CAPCUT_TRANSFER_SNAPSHOT_PACKAGE"] { openPackage(URL(fileURLWithPath: pkg)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                self.table.selectRowIndexes([0, 1], byExtendingSelection: false)
                for (i, name) in ["export", "import"].enumerated() {
                    self.modeControl.selectedSegment = i; self.modeChanged(); self.window.contentView!.layoutSubtreeIfNeeded()
                    let v = self.window.contentView!.superview!
                    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) { v.cacheDisplay(in: v.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png")) }
                }
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { job?.cancel(); tempFolders.forEach { try? fm.removeItem(at: $0) } }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let u = urls.first(where: DropView.accepts) else { return }
        if window == nil { pendingOpen = u } else { openPackage(u) }
    }

    func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: t("Informazioni su CapCut Transfer", "About CapCut Transfer"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: t("Nascondi CapCut Transfer", "Hide CapCut Transfer"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: t("Esci", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem(); menu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: t("Apri pacchetto…", "Open Package…"), action: #selector(choosePackage), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: t("Aggiorna elenco progetti", "Refresh Project List"), action: #selector(reloadProjects), keyEquivalent: "r").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: t("Chiudi finestra", "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let editMenu = NSMenu(title: t("Modifica", "Edit"))
        editMenu.addItem(withTitle: t("Copia", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: t("Incolla", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: t("Seleziona tutto", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(withTitle: t("Cerca", "Find"), action: #selector(focusSearch), keyEquivalent: "f").target = self
        editItem.submenu = editMenu
        let helpItem = NSMenuItem(); menu.addItem(helpItem)
        let helpMenu = NSMenu(title: t("Aiuto", "Help"))
        helpMenu.addItem(withTitle: t("Pagina del progetto su GitHub", "Project Page on GitHub"), action: #selector(openProjectPage), keyEquivalent: "").target = self
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = menu
    }
    @objc func openProjectPage() { NSWorkspace.shared.open(projectPage) }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "CapCut Transfer"; window.minSize = NSSize(width: 640, height: 480); window.setFrameAutosaveName("Main")
        if window.frame.origin == .zero { window.center() }
        let content = window.contentView!

        // Header: mode switch + live CapCut state
        modeControl.selectedSegment = 0; modeControl.target = self; modeControl.action = #selector(modeChanged)
        capCutDot.font = .systemFont(ofSize: 11); capCutLabel.font = .systemFont(ofSize: 12); capCutLabel.textColor = .secondaryLabelColor
        quitCapCut.target = self; quitCapCut.action = #selector(closeCapCut); quitCapCut.bezelStyle = .rounded; quitCapCut.controlSize = .small
        let header = hstack([modeControl, spacer(), capCutDot, capCutLabel, quitCapCut], spacing: 6)

        // Export tab
        search.placeholderString = t("Cerca progetto", "Search projects"); search.delegate = self; search.sendsSearchStringImmediately = true
        search.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let refresh = NSButton(title: t("Aggiorna", "Refresh"), target: self, action: #selector(reloadProjects)); refresh.bezelStyle = .rounded
        let hint = label(t("Seleziona uno o più progetti (⌘ o ⇧ per sceglierne più di uno).", "Select one or more projects (⌘ or ⇧ to pick several)."), size: 12, color: .secondaryLabelColor)
        let col = NSTableColumn(identifier: .init("p")); col.resizingMask = .autoresizingMask
        table.addTableColumn(col); table.headerView = nil; table.rowHeight = 58; table.allowsMultipleSelection = true
        table.dataSource = self; table.delegate = self; table.doubleAction = #selector(revealProject); table.target = self
        if #available(macOS 11.0, *) { table.style = .inset }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.drawsBackground = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle; table.sizeLastColumnToFit()
        summary.textColor = .secondaryLabelColor; summary.font = .systemFont(ofSize: 12)
        zipOption.font = .systemFont(ofSize: 12); zipOption.target = self; zipOption.action = #selector(zipOptionChanged)
        zipOption.state = UserDefaults.standard.bool(forKey: "zipAfterExport") ? .on : .off
        zipOption.toolTip = t("Utile per Google Drive, WeTransfer o email. Per AirDrop o chiavetta non serve.", "Useful for Google Drive, WeTransfer or email. Not needed for AirDrop or a USB drive.")
        exportButton.target = self; exportButton.action = #selector(exportSelected); exportButton.bezelStyle = .rounded; exportButton.keyEquivalent = "\r"
        let exportView = NSStackView(views: [hstack([search, hint, spacer(), refresh]), scroll, hstack([summary, spacer(), zipOption, exportButton])])
        exportView.orientation = .vertical; exportView.alignment = .leading; exportView.spacing = 12
        for v in exportView.arrangedSubviews { v.widthAnchor.constraint(equalTo: exportView.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Import tab
        let dropTitle = label(t("Trascina qui un pacchetto .capcuttransfer o il suo .zip", "Drop a .capcuttransfer package or its .zip here"), size: 15, weight: .semibold); dropTitle.alignment = .center
        let dropText = label(t("Puoi anche fare doppio clic sul pacchetto nel Finder.", "You can also double-click the package in the Finder."), size: 12, color: .secondaryLabelColor); dropText.alignment = .center
        let chooseButton = NSButton(title: t("Scegli pacchetto…", "Choose Package…"), target: self, action: #selector(choosePackage)); chooseButton.bezelStyle = .rounded
        let dropStack = NSStackView(views: [dropTitle, dropText, chooseButton]); dropStack.orientation = .vertical; dropStack.spacing = 8
        dropStack.translatesAutoresizingMaskIntoConstraints = false; drop.addSubview(dropStack)
        NSLayoutConstraint.activate([dropStack.centerXAnchor.constraint(equalTo: drop.centerXAnchor), dropStack.centerYAnchor.constraint(equalTo: drop.centerYAnchor),
                                     dropStack.widthAnchor.constraint(lessThanOrEqualTo: drop.widthAnchor, constant: -32), drop.heightAnchor.constraint(equalToConstant: 150)])
        drop.onDrop = { [weak self] u in self?.openPackage(u) }
        packageInfo.font = .systemFont(ofSize: 13); packageInfo.isSelectable = true
        destinationLabel.font = .systemFont(ofSize: 12); destinationLabel.textColor = .secondaryLabelColor; destinationLabel.lineBreakMode = .byTruncatingMiddle
        destinationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let changeDest = NSButton(title: t("Cambia…", "Change…"), target: self, action: #selector(chooseDestination)); changeDest.bezelStyle = .rounded; changeDest.controlSize = .small
        importButton.target = self; importButton.action = #selector(importPackage); importButton.bezelStyle = .rounded
        let importView = NSStackView(views: [drop, packageInfo, spacer(), hstack([destinationLabel, changeDest, spacer(), importButton])])
        importView.orientation = .vertical; importView.alignment = .leading; importView.spacing = 14
        for v in importView.arrangedSubviews { v.widthAnchor.constraint(equalTo: importView.widthAnchor).isActive = true }
        importView.arrangedSubviews[2].setContentHuggingPriority(.init(1), for: .vertical)

        tabs.tabViewType = .noTabsNoBorder
        for (id, v) in [("export", exportView), ("import", importView)] {
            // Pin each tab's stack to a plain container so it always fills the whole tab area.
            let box = NSView(); v.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(v)
            NSLayoutConstraint.activate([v.leadingAnchor.constraint(equalTo: box.leadingAnchor), v.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                                         v.topAnchor.constraint(equalTo: box.topAnchor), v.bottomAnchor.constraint(equalTo: box.bottomAnchor)])
            let item = NSTabViewItem(identifier: id); item.view = box; tabs.addTabViewItem(item)
        }

        // Footer: progress + status
        progress.isIndeterminate = false; progress.style = .bar; progress.minValue = 0; progress.maxValue = 1
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular); progressLabel.textColor = .secondaryLabelColor; progressLabel.lineBreakMode = .byTruncatingMiddle
        progressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cancelButton.target = self; cancelButton.action = #selector(cancelJob); cancelButton.bezelStyle = .rounded; cancelButton.keyEquivalent = "\u{1b}"
        let bars = NSStackView(views: [progress, progressLabel]); bars.orientation = .vertical; bars.alignment = .leading; bars.spacing = 4
        progress.widthAnchor.constraint(equalTo: bars.widthAnchor).isActive = true
        progressRow = hstack([bars, cancelButton]); progressRow.isHidden = true
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        followUp.target = self; followUp.action = #selector(runFollowUp); followUp.bezelStyle = .rounded; followUp.isHidden = true
        let statusRow = hstack([status, spacer(), followUp])

        let rootStack = NSStackView(views: [header, tabs, progressRow, statusRow])
        rootStack.orientation = .vertical; rootStack.alignment = .leading; rootStack.spacing = 14; rootStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rootStack)
        for v in rootStack.arrangedSubviews { v.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true }
        tabs.setContentHuggingPriority(.init(1), for: .vertical)
        NSLayoutConstraint.activate([rootStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), rootStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                                     rootStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14), rootStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)])
    }

    // MARK: State

    var busy: Bool { job != nil }
    var capCutRunning: Bool { !runningCapCut().isEmpty }

    func refreshCapCut() {
        let running = capCutRunning
        capCutDot.textColor = running ? .systemOrange : .systemGreen
        capCutLabel.stringValue = running ? t("CapCut è aperto", "CapCut is open") : t("CapCut è chiuso", "CapCut is closed")
        quitCapCut.isHidden = !running
        updateSummary(); updateImport()
    }
    @objc func closeCapCut() { runningCapCut().forEach { $0.terminate() }; capCutLabel.stringValue = t("Chiusura di CapCut…", "Quitting CapCut…") }
    @objc func modeChanged() { tabs.selectTabViewItem(at: modeControl.selectedSegment) }
    @objc func focusSearch() { modeControl.selectedSegment = 0; modeChanged(); window.makeFirstResponder(search) }
    @objc func zipOptionChanged() { UserDefaults.standard.set(zipOption.state == .on, forKey: "zipAfterExport") }
    func setStatus(_ s: String, color: NSColor = .secondaryLabelColor, action: (String, () -> Void)? = nil) {
        status.stringValue = s; status.textColor = color
        followUp.isHidden = action == nil; followUp.title = action?.0 ?? ""; followUpAction = action?.1
    }
    @objc func runFollowUp() { followUpAction?() }
    func alert(_ title: String, _ message: String, style: NSAlert.Style = .warning) {
        let a = NSAlert(); a.alertStyle = style; a.messageText = title; a.informativeText = message; a.beginSheetModal(for: window)
    }
    let closeCapCutFirst = t("Chiudi CapCut prima di continuare.", "Quit CapCut before continuing.")

    // MARK: Project list

    @objc func reloadProjects() {
        scanGeneration += 1; let gen = scanGeneration; let root = self.root
        summary.stringValue = t("Cerco i progetti in \(root.path)…", "Looking for projects in \(root.path)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            let items = folders.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .compactMap(ProjectItem.load).sorted { $0.modified > $1.modified }
            DispatchQueue.main.async {
                guard gen == self.scanGeneration else { return }
                self.projects = items; self.applyFilter(); self.updateSummary()
                for item in items {
                    DispatchQueue.global(qos: .utility).async {
                        var scan: ProjectScan?, err: String?
                        do { scan = try Engine.analyze(item.url) } catch { err = error.localizedDescription }
                        DispatchQueue.main.async {
                            guard gen == self.scanGeneration else { return }
                            item.scan = scan; item.scanError = err
                            if let row = self.shown.firstIndex(where: { $0 === item }) { self.table.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
                            self.updateSummary()
                        }
                    }
                }
            }
        }
    }
    func applyFilter() {
        let selected = Set(selectedProjects().map { $0.url })
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        shown = q.isEmpty ? projects : projects.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.url.lastPathComponent.localizedCaseInsensitiveContains(q) }
        table.reloadData()
        table.selectRowIndexes(IndexSet(shown.indices.filter { selected.contains(shown[$0].url) }), byExtendingSelection: false)
    }
    func controlTextDidChange(_ obj: Notification) { applyFilter() }
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("cell"), owner: nil) as? ProjectCell ?? { let c = ProjectCell(); c.identifier = .init("cell"); return c }()
        cell.show(shown[row], dates); return cell
    }
    func tableViewSelectionDidChange(_ n: Notification) { updateSummary() }
    func selectedProjects() -> [ProjectItem] { table.selectedRowIndexes.filter { $0 < shown.count }.map { shown[$0] } }
    @objc func revealProject() { if table.clickedRow >= 0 { NSWorkspace.shared.activateFileViewerSelecting([shown[table.clickedRow].url]) } }

    func updateSummary() {
        let sel = selectedProjects()
        var enable = !sel.isEmpty && !busy
        if !fm.fileExists(atPath: root.path) {
            summary.stringValue = t("Cartella progetti CapCut non trovata. Avvia CapCut almeno una volta su questo Mac.", "CapCut's project folder wasn't found. Open CapCut at least once on this Mac."); enable = false
        }
        else if projects.isEmpty { summary.stringValue = t("Nessun progetto trovato in com.lveditor.draft.", "No projects found in com.lveditor.draft.") }
        else if sel.isEmpty { summary.stringValue = plural(projects.count, "progetto su questo Mac.", "progetti su questo Mac.", "project on this Mac.", "projects on this Mac.") }
        else {
            let scanned = sel.compactMap { $0.scan }
            var parts = [plural(sel.count, "progetto", "progetti", "project", "projects")]
            if scanned.count == sel.count { parts.append(bytes(scanned.reduce(0) { $0 + $1.bytes })) } else { parts.append(t("calcolo dimensioni…", "measuring…")); enable = false }
            if let free = freeSpace(at: root) { parts.append(t("liberi ", "free ") + bytes(free)) }
            let missing = sel.filter { ($0.scan?.missing.isEmpty == false) || $0.scanError != nil }
            if !missing.isEmpty { parts.append(t("\(missing.count) con file mancanti", "\(missing.count) with missing files")) }
            if capCutRunning { parts.append(t("chiudi CapCut per esportare", "quit CapCut to export")); enable = false }
            summary.stringValue = parts.joined(separator: " · ")
        }
        exportButton.isEnabled = enable
        exportButton.title = sel.count > 1 ? t("Esporta \(sel.count) progetti…", "Export \(sel.count) Projects…") : t("Esporta…", "Export…")
    }

    // MARK: Export

    @objc func exportSelected() {
        let sel = selectedProjects(); guard !sel.isEmpty, !busy else { return }
        guard !capCutRunning else { alert(closeCapCutFirst, t("CapCut deve restare chiuso mentre i file vengono copiati.", "CapCut must stay closed while files are being copied.")); return }
        let broken = sel.filter { !$0.ready }
        if !broken.isEmpty {
            let text = broken.map { p in "• \(p.name)\n" + (p.scanError ?? Engine.missingMessage(p.scan?.missing ?? [])) }.joined(separator: "\n\n")
            alert(broken.count == 1 ? t("Il progetto non può essere esportato", "This project can't be exported")
                                    : t("\(broken.count) progetti non possono essere esportati", "\(broken.count) projects can't be exported"), text); return
        }
        var targets = [(ProjectItem, URL)]()
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
        if sel.count == 1 {
            let p = NSSavePanel(); p.title = t("Salva pacchetto", "Save Package"); p.nameFieldStringValue = safeName(sel[0].name) + ".capcuttransfer"; p.canCreateDirectories = true; p.directoryURL = desktop
            guard p.runModal() == .OK, let u = p.url else { return }
            if fm.fileExists(atPath: u.path) { alert(t("Esiste già un pacchetto con questo nome.", "A package with this name already exists."), t("Scegli un altro nome o sposta il pacchetto esistente.", "Choose another name or move the existing package.")); return }
            targets = [(sel[0], u)]
        } else {
            let p = NSOpenPanel(); p.message = t("Scegli dove salvare i \(sel.count) pacchetti", "Choose where to save the \(sel.count) packages"); p.prompt = t("Salva qui", "Save Here")
            p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.directoryURL = desktop
            guard p.runModal() == .OK, let dir = p.url else { return }
            var used = Set<String>()
            for item in sel {
                var name = safeName(item.name), n = 2
                while used.contains(name) || fm.fileExists(atPath: dir.appendingPathComponent(name + ".capcuttransfer").path) { name = safeName(item.name) + " \(n)"; n += 1 }
                used.insert(name); targets.append((item, dir.appendingPathComponent(name + ".capcuttransfer")))
            }
        }
        if let dir = targets.first?.1.deletingLastPathComponent(), sel.contains(where: { dir.standardizedFileURL.path.hasPrefix($0.url.standardizedFileURL.path) }) {
            alert(t("Scegli un'altra posizione.", "Choose another location."), t("Salva il pacchetto fuori dalla cartella del progetto.", "Save the package outside the project folder.")); return
        }
        let makeZip = zipOption.state == .on
        if makeZip, let clash = targets.first(where: { fm.fileExists(atPath: $0.1.appendingPathExtension("zip").path) }) {
            alert(t("Esiste già un file con questo nome.", "A file with this name already exists."), clash.1.appendingPathExtension("zip").path); return
        }
        let needed = sel.reduce(Int64(0)) { $0 + ($1.scan?.bytes ?? 0) } * (makeZip ? 2 : 1)
        if let dir = targets.first?.1.deletingLastPathComponent(), let free = freeSpace(at: dir), free < needed + 200_000_000 {
            alert(t("Spazio insufficiente", "Not enough space"), t("Servono \(bytes(needed)), sul disco scelto ci sono \(bytes(free)) liberi.", "\(bytes(needed)) needed, the chosen disk has \(bytes(free)) free.")); return
        }
        run(title: t("Esportazione", "Export")) { job in
            var outputs = [URL]()
            for (i, (item, url)) in targets.enumerated() {
                job.step(targets.count > 1 ? t("Progetto \(i + 1) di \(targets.count): \(item.name)", "Project \(i + 1) of \(targets.count): \(item.name)") : item.name)
                try Engine.export(item.url, to: url, scan: item.scan, job: job)
                outputs.append(url)
                if makeZip { outputs.append(try Engine.zip(url, job: job)) }
            }
            let packages = targets.map { $0.1 }
            var msg = packages.count == 1
                ? t("Pacchetto creato: \(packages[0].lastPathComponent).", "Package created: \(packages[0].lastPathComponent).")
                : t("\(packages.count) pacchetti creati in \(packages[0].deletingLastPathComponent().lastPathComponent).", "\(packages.count) packages created in \(packages[0].deletingLastPathComponent().lastPathComponent).")
            if makeZip { msg += t(" Per l'invio online usa il file .zip.", " Use the .zip file to send it online.") }
            msg += t(" Aprilo sull'altro Mac con CapCut Transfer.", " Open it on the other Mac with CapCut Transfer.")
            return (msg, (t("Mostra nel Finder", "Show in Finder"), { NSWorkspace.shared.activateFileViewerSelecting(outputs) }))
        }
    }
    func safeName(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? t("Progetto", "Project") : cleaned
    }

    // MARK: Import

    @objc func choosePackage() {
        let p = NSOpenPanel(); p.message = t("Scegli un pacchetto .capcuttransfer o un .zip che lo contiene", "Choose a .capcuttransfer package or a .zip that contains one")
        p.canChooseFiles = true; p.canChooseDirectories = true; p.treatsFilePackagesAsDirectories = false
        p.directoryURL = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard p.runModal() == .OK, let u = p.url else { return }
        openPackage(u)
    }
    func openPackage(_ u: URL) {
        modeControl.selectedSegment = 1; modeChanged()
        guard !busy else { return }
        let ready = t("Pacchetto pronto. Controlla i dettagli e premi Importa.", "Package ready. Check the details and click Import.")
        if u.pathExtension.lowercased() == "zip" {
            run(title: t("Estrazione", "Extraction"), showAlert: false) { [weak self] job in
                let pkg = try Engine.unzip(u, job: job)
                let info = try Engine.inspect(pkg)
                DispatchQueue.main.async { self?.tempFolders.append(pkg.lastPathComponent.hasPrefix("CapCutTransfer-") ? pkg : pkg.deletingLastPathComponent()); self?.package = info; self?.updateImport() }
                return (ready, nil)
            }
            return
        }
        do { package = try Engine.inspect(u); updateImport(); setStatus(ready) }
        catch { package = nil; updateImport(); alert(t("Impossibile aprire il pacchetto", "Can't open the package"), error.localizedDescription) }
    }
    @objc func chooseDestination() {
        let p = NSOpenPanel(); p.message = t("Scegli la cartella com.lveditor.draft indicata nelle impostazioni di CapCut", "Choose the com.lveditor.draft folder shown in CapCut's settings")
        p.canChooseDirectories = true; p.canChooseFiles = false; p.treatsFilePackagesAsDirectories = true; p.directoryURL = root
        guard p.runModal() == .OK, let u = p.url else { return }
        guard u.lastPathComponent == "com.lveditor.draft" else {
            alert(t("Cartella non valida", "Wrong folder"), t("Scegli la cartella com.lveditor.draft indicata nelle impostazioni di CapCut.", "Choose the com.lveditor.draft folder shown in CapCut's settings.")); return
        }
        root = u; updateDestination(); reloadProjects()
    }
    func updateDestination() {
        let short = root.path.replacingOccurrences(of: fm.homeDirectoryForCurrentUser.path, with: "~")
        destinationLabel.stringValue = fm.fileExists(atPath: root.path) ? t("Destinazione: ", "Destination: ") + short
                                                                          : t("Cartella CapCut non trovata: avvia CapCut una volta o scegli la cartella.", "CapCut folder not found: open CapCut once or choose the folder.")
        destinationLabel.toolTip = root.path
        updateImport()
    }
    func updateImport() {
        importButton.isEnabled = package != nil && !busy && !capCutRunning && fm.fileExists(atPath: root.path)
        guard let p = package else {
            packageInfo.stringValue = t("Nessun pacchetto selezionato. Il progetto importato comparirà in CapCut con il suffisso “(importato)”; l'originale resta nel pacchetto.",
                                        "No package selected. The imported project will appear in CapCut with “(imported)” after its name; the original stays in the package.")
            packageInfo.textColor = .secondaryLabelColor; return
        }
        packageInfo.textColor = .labelColor
        var lines = ["“\(p.name)”", plural(p.files, "file", "file", "file", "files") + " · \(bytes(p.bytes))"]
        var origin = [String]()
        if let m = p.sourceMac { origin.append(t("da ", "on ") + m) }
        if let d = p.createdAt { origin.append(dates.string(from: d)) }
        if !origin.isEmpty { lines.append(t("Creato ", "Created ") + origin.joined(separator: ", ")) }
        let local = installedCapCutVersion()
        switch (p.capCutVersion, local) {
        case let (a?, b?) where a != b:
            lines.append(t("⚠︎ CapCut \(a) sul Mac di origine, \(b) qui. Aggiorna CapCut alla stessa versione se il progetto non si apre bene.",
                           "⚠︎ CapCut \(a) on the source Mac, \(b) here. Update CapCut to the same version if the project doesn't open correctly."))
        case let (a?, _?): lines.append(t("✓ Stessa versione di CapCut (\(a))", "✓ Same CapCut version (\(a))"))
        case (nil, _): lines.append(t("Pacchetto creato con una versione precedente dell'app: versione di CapCut non indicata.", "Package made with an older version of this app: CapCut version unknown."))
        case (_, nil): lines.append(t("⚠︎ CapCut non risulta installato su questo Mac.", "⚠︎ CapCut doesn't seem to be installed on this Mac."))
        }
        lines.append(p.hasChecksums ? t("✓ L'integrità di ogni file verrà verificata durante l'importazione.", "✓ Every file will be checked for damage during the import.")
                                    : t("Nessun controllo d'integrità disponibile per questo pacchetto.", "No integrity check available for this package."))
        if capCutRunning { lines.append(t("Chiudi CapCut per importare.", "Quit CapCut to import.")) }
        packageInfo.stringValue = lines.joined(separator: "\n")
    }
    @objc func importPackage() {
        guard let p = package, !busy else { return }
        guard !capCutRunning else { alert(closeCapCutFirst, t("CapCut deve restare chiuso mentre il progetto viene importato.", "CapCut must stay closed while the project is imported.")); return }
        let root = self.root
        run(title: t("Importazione", "Import"), isImport: true) { job in
            job.step(p.name)
            _ = try Engine.restore(p.url, into: root, job: job)
            return (t("Progetto importato come “\(p.name) (importato)”. Apri CapCut e controlla il montaggio.", "Project imported as “\(p.name) (imported)”. Open CapCut and check the edit."),
                    (t("Apri CapCut", "Open CapCut"), {
                        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: capCutBundleID) { NSWorkspace.shared.open(app) }
                    }))
        }
    }

    // MARK: Background work

    func run(title: String, showAlert: Bool = true, isImport: Bool = false, _ task: @escaping (Job) throws -> (String, (String, () -> Void)?)) {
        let job = Job(); self.job = job
        progress.isIndeterminate = true; progress.startAnimation(nil); progressLabel.stringValue = t("Preparazione…", "Preparing…")
        progressRow.isHidden = false; setStatus(t("\(title) in corso. Puoi annullare in qualsiasi momento.", "\(title) in progress. You can cancel at any time."))
        updateSummary(); updateImport()
        job.onChange = { [weak self] j in DispatchQueue.main.async { self?.showProgress(j) } }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try task(job) }
            DispatchQueue.main.async {
                self.job = nil; self.progress.stopAnimation(nil); self.progressRow.isHidden = true
                switch result {
                case .success(let (msg, action)):
                    self.setStatus(msg, color: .labelColor, action: action)
                    if isImport { self.package = nil }
                    if showAlert { NSApp.requestUserAttention(.informationalRequest) }
                case .failure(let e) where e is Cancelled:
                    self.setStatus(t("\(title) annullata. Nessun file parziale è stato lasciato.", "\(title) cancelled. No partial files were left behind."))
                case .failure(let e):
                    self.setStatus(t("\(title) interrotta.", "\(title) stopped."), color: .systemRed)
                    self.alert(t("\(title) interrotta", "\(title) stopped"), e.localizedDescription)
                }
                self.updateSummary(); self.updateImport()
                if isImport { self.reloadProjects() }
            }
        }
    }
    func showProgress(_ j: Job) {
        guard job === j else { return }
        let s = j.snapshot
        if s.total > 0 && s.done < s.total {
            progress.isIndeterminate = false; progress.maxValue = Double(s.total); progress.doubleValue = Double(s.done)
            var text = "\(s.item) · " + t("\(bytes(s.done)) di \(bytes(s.total))", "\(bytes(s.done)) of \(bytes(s.total))")
            let elapsed = Date().timeIntervalSince(j.started)
            if s.done > 0, elapsed > 2 {
                let left = elapsed * Double(s.total - s.done) / Double(s.done)
                text += left < 60 ? t(" · meno di un minuto", " · less than a minute") : t(" · circa \(Int((left / 60).rounded())) min", " · about \(Int((left / 60).rounded())) min")
            }
            progressLabel.stringValue = text
        } else {
            // Steps without a byte count (zipping, extracting, rewriting paths) show a spinning bar.
            if s.total > 0 { progress.isIndeterminate = true; progress.startAnimation(nil) }
            progressLabel.stringValue = s.item
        }
    }
    @objc func cancelJob() { job?.cancel(); progressLabel.stringValue = t("Annullamento…", "Cancelling…") }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--test-process-check") {
    assert(!capCutIsRunning(["com.enrico.capcuttransfer"]))
    assert(!capCutIsRunning([]))
    assert(capCutIsRunning(["com.enrico.capcuttransfer", "com.lemon.lvoverseas"]))
    print("PASS: controllo CapCut per identificativo; esclusa CapCut Transfer")
} else if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--test-export" {
    try Engine.export(URL(fileURLWithPath: CommandLine.arguments[2]), to: URL(fileURLWithPath: CommandLine.arguments[3]))
    print(try Engine.restore(URL(fileURLWithPath: CommandLine.arguments[3]), into: URL(fileURLWithPath: CommandLine.arguments[4])).path)
} else if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--test-export-only" {
    try Engine.export(URL(fileURLWithPath: CommandLine.arguments[2]), to: URL(fileURLWithPath: CommandLine.arguments[3]))
    print("OK")
} else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--test-zip" {
    print(try Engine.zip(URL(fileURLWithPath: CommandLine.arguments[2]), job: nil).path)
} else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--test-unzip" {
    print(try Engine.unzip(URL(fileURLWithPath: CommandLine.arguments[2]), job: nil).path)
} else if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--test-import" {
    do { print(try Engine.restore(URL(fileURLWithPath: CommandLine.arguments[2]), into: URL(fileURLWithPath: CommandLine.arguments[3])).path) }
    catch { print("ERRORE: \(error.localizedDescription)"); exit(2) }
} else {
    let app = NSApplication.shared; let delegate = App(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
}
