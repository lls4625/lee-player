import Foundation

enum LibraryFailure: LocalizedError {
  case app(code: String, args: [String: Any], technicalDetail: String?)

  static func app(_ code: String, args: [String: Any] = [:], technicalDetail: String? = nil) -> LibraryFailure {
    .app(code: code, args: args, technicalDetail: technicalDetail)
  }

  var code: String {
    if case .app(let code, _, _) = self { return code }
    return "operation_failed"
  }

  var args: [String: Any] {
    if case .app(_, let args, _) = self { return args }
    return [:]
  }

  var technicalDetail: String? {
    if case .app(_, _, let detail) = self { return detail }
    return nil
  }

  var errorDescription: String? { technicalDetail ?? code }
}

final class ImportCancellation {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

struct LibraryScanSnapshot {
  let items: [[String: Any]]
  let warnings: [[String: Any]]
  let protectionPaths: [String]
}

/// The queue owns all record mutations and disk I/O. The lock only protects a
/// value snapshot, so the playback thread never waits for a disk operation.
final class LibraryRecordStore {
  typealias Records = [String: [String: Any]]
  private let work = DispatchQueue(label: "雷player.records", qos: .utility)
  private let lock = NSLock()
  private let root: URL
  private let support: URL
  private var value: Records = [:]
  private var cached: Records = [:]
  private var issue: String? = "library_records_loading"
  private var cachedIssue: String? = "library_records_loading"
  private var snapshotRevision = 0
  private var epoch = 0
  private var dirty: Records = [:]
  private var retry: DispatchWorkItem?
  private var failures = 0
  private var loaded = false
  private var initialLoadFinished = false
  private var revision = 0
  private var lastRecoveryAttempt = Date.distantPast
  var changed: (() -> Void)? // Installed and invoked on the main thread.
  private var file: URL { support.appendingPathComponent("library.json") }
  private var journal: URL { support.appendingPathComponent("library-operation.json") }

  init(root: URL, support: URL) {
    self.root = root; self.support = support
    work.async {
      self.load()
      self.lock.lock(); self.initialLoadFinished = true; self.lock.unlock()
    }
  }

  var snapshot: Records { lock.lock(); defer { lock.unlock() }; return cached }
  var status: String? { lock.lock(); defer { lock.unlock() }; return cachedIssue }
  var state: [String: Any] {
    lock.lock(); defer { lock.unlock() }
    return ["records": cached, "status": cachedIssue ?? "healthy", "revision": snapshotRevision]
  }
  func afterInitialLoad(_ completion: @escaping () -> Void) {
    lock.lock(); let ready = initialLoadFinished; lock.unlock()
    if ready { completion() }
    else { work.async { DispatchQueue.main.async(execute: completion) } }
  }
  private var currentEpoch: Int { lock.lock(); defer { lock.unlock() }; return epoch }

  private func publish(invalidate: Bool = false) {
    lock.lock()
    cached = value; cachedIssue = issue
    snapshotRevision += 1
    if invalidate { epoch += 1 }
    lock.unlock()
    DispatchQueue.main.async { [weak self] in self?.changed?() }
  }

  private func write(_ next: Records) throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "version": 1, "revision": revision + 1, "records": next,
    ])
    try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    revision += 1
    value = next
    issue = nil; failures = 0
  }

  private func valid(_ records: Records) -> Bool {
    records.allSatisfy { path, fields in
      guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return false }
      for key in ["position", "duration", "timelineOrigin", "lastPlayed"] {
        if let field = fields[key] {
          guard let number = field as? NSNumber, number.doubleValue.isFinite else { return false }
        }
      }
      for key in ["favorite", "completed"] {
        if let field = fields[key], !(field is Bool) { return false }
      }
      return true
    }
  }

  private func load() {
    do {
      let data: Data
      do { data = try Data(contentsOf: file) }
      catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
        // A recovery journal is never treated as a new, empty installation.
        guard !loaded, !FileManager.default.fileExists(atPath: journal.path) else {
          throw LibraryFailure.app("library_records_corrupt")
        }
        try write([:]); loaded = true; publish(); return
      }
      let object: [String: Any]
      do {
        guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          throw LibraryFailure.app("library_records_corrupt")
        }
        object = decoded
      } catch {
        preserve(data)
        throw LibraryFailure.app("library_records_corrupt")
      }
      if let version = object["version"] as? Int {
        guard version == 1 else { throw LibraryFailure.app("library_records_version") }
        guard let records = object["records"] as? Records, valid(records) else {
          preserve(data); throw LibraryFailure.app("library_records_corrupt")
        }
        value = records; revision = object["revision"] as? Int ?? 0
      } else {
        guard let records = object as? Records, valid(records) else {
          preserve(data); throw LibraryFailure.app("library_records_corrupt")
        }
        // Keep the exact legacy bytes before the first versioned commit.
        let backup = support.appendingPathComponent("library-legacy-\(UUID().uuidString).json")
        try data.write(to: backup, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try write(records)
      }
      loaded = true; issue = nil
      try recoverJournal()
      publish()
    } catch {
      issue = (error as? LibraryFailure)?.code ?? "library_records_unavailable"
      publish()
    }
  }

  private func preserve(_ data: Data) {
    // Never replace the source, even if the backup cannot be written.
    let backup = support.appendingPathComponent("library-corrupt-\(UUID().uuidString).json")
    try? data.write(to: backup, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  func retryStorage() {
    work.async {
      guard Date().timeIntervalSince(self.lastRecoveryAttempt) >= 1 else { return }
      self.lastRecoveryAttempt = Date()
      guard !["library_records_corrupt", "library_records_version"].contains(self.issue ?? "") else { return }
      if !self.loaded || FileManager.default.fileExists(atPath: self.journal.path) { self.load() }
      else if self.issue != nil || !self.dirty.isEmpty { self.flush() }
    }
  }

  private func requireWritable() throws {
    guard loaded, issue == nil || issue == "library_records_unavailable" else {
      throw LibraryFailure.app(issue ?? "library_records_unavailable")
    }
    guard !FileManager.default.fileExists(atPath: journal.path) else {
      throw LibraryFailure.app("library_records_recovery")
    }
  }

  private func merged() -> Records {
    var next = value
    for (path, fields) in dirty {
      next[path, default: [:]].merge(fields) { _, new in new }
    }
    return next
  }

  func updateProgress(path: String, fields: [String: Any]) {
    let submittedEpoch = currentEpoch
    work.async {
      guard submittedEpoch == self.currentEpoch, self.loaded,
        FileManager.default.fileExists(atPath: self.root.appendingPathComponent(path).path),
        self.issue == nil || self.issue == "library_records_unavailable" else { return }
      self.dirty[path, default: [:]].merge(fields) { _, new in new }
      if self.retry == nil { self.flush() }
    }
  }

  private func flush() {
    retry?.cancel(); retry = nil
    do {
      try requireWritable()
      try write(merged()); dirty.removeAll(); publish()
    } catch {
      issue = (error as? LibraryFailure)?.code ?? "library_records_unavailable"
      failures += 1
      // Transient first failures recover silently; persistent failures get one
      // page status. Retry at bounded frequency, never at the player heartbeat.
      if failures >= 3 || issue != "library_records_unavailable" { publish() }
      if failures <= 5, issue == "library_records_unavailable" {
        let task = DispatchWorkItem { [weak self] in self?.flush() }
        retry = task
        work.asyncAfter(deadline: .now() + min(30, pow(2, Double(failures))), execute: task)
      }
    }
  }

  func mutate(_ change: (inout Records) -> Void) throws {
    try work.sync {
      do {
        try self.requireWritable()
        var next = self.merged(); change(&next)
        try self.write(next); self.dirty.removeAll(); self.publish(invalidate: true)
      } catch {
        self.issue = (error as? LibraryFailure)?.code ?? "library_records_unavailable"
        self.publish()
        throw LibraryFailure.app(self.issue ?? "library_records_unavailable", technicalDetail: error.localizedDescription)
      }
    }
  }

  /// Called only on the library worker, never the main thread. The journal is
  /// durable before the file step and blocks later writes until reconciled.
  func fileMutation(kind: String, source: URL, destination: URL?,
                    change: (inout Records) -> Void) throws {
    try work.sync {
      try requireWritable()
      var next = merged(); change(&next)
      let document: [String: Any] = ["version": 1, "operationId": UUID().uuidString,
        "kind": kind, "source": try location(source),
        "destination": try destination.map { try location($0) } ?? "", "records": next]
      try JSONSerialization.data(withJSONObject: document).write(to: journal,
        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      publish(invalidate: true)
      var fileChanged = false
      do {
        if let destination { try FileManager.default.moveItem(at: source, to: destination) }
        else { try FileManager.default.removeItem(at: source) }
        fileChanged = true
        try write(next); dirty.removeAll()
        try FileManager.default.removeItem(at: journal)
        publish()
      } catch {
        // Reflect the actual file location in this session, without claiming a
        // durable record commit. The journal retains the recovery candidate.
        if fileChanged { value = next; dirty.removeAll() }
        issue = "library_records_recovery"; publish()
        throw LibraryFailure.app("library_records_recovery", technicalDetail: error.localizedDescription)
      }
    }
  }

  private func location(_ url: URL) throws -> String {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    if path.hasPrefix(root.path + "/") { return "root/" + String(path.dropFirst(root.path.count + 1)) }
    if path.hasPrefix(support.appendingPathComponent("Trash").path + "/") {
      return "support/" + String(path.dropFirst(support.path.count + 1))
    }
    throw LibraryFailure.app("library_records_recovery")
  }

  private func resolveLocation(_ path: String) throws -> URL {
    let url: URL
    if path.hasPrefix("root/") { url = root.appendingPathComponent(String(path.dropFirst(5))) }
    else if path.hasPrefix("support/Trash/") { url = support.appendingPathComponent(String(path.dropFirst(8))) }
    else { throw LibraryFailure.app("library_records_recovery") }
    let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
    guard try location(resolved) == path else { throw LibraryFailure.app("library_records_recovery") }
    return resolved
  }

  private func recoverJournal() throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: journal.path) else { return }
    guard let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any],
      doc["version"] as? Int == 1, let kind = doc["kind"] as? String,
      let sourcePath = doc["source"] as? String, let destinationPath = doc["destination"] as? String,
      let next = doc["records"] as? Records, valid(next) else { throw LibraryFailure.app("library_records_recovery") }
    let source = try resolveLocation(sourcePath)
    let trash = support.appendingPathComponent("Trash").path + "/"
    func allowed(_ url: URL) -> Bool { url.path.hasPrefix(root.path + "/") || url.path.hasPrefix(trash) }
    guard allowed(source) else { throw LibraryFailure.app("library_records_recovery") }
    if kind == "move" {
      let destination = try resolveLocation(destinationPath)
      guard allowed(destination) else { throw LibraryFailure.app("library_records_recovery") }
      let fromExists = fm.fileExists(atPath: source.path), toExists = fm.fileExists(atPath: destination.path)
      if !fromExists && toExists { try write(next); dirty.removeAll() }
      else if !(fromExists && !toExists) { throw LibraryFailure.app("library_records_recovery") }
      // Source only: the file step never completed; retain the committed records.
    } else if kind == "purge", source.path.hasPrefix(trash) {
      // This token was explicitly selected for permanent removal. Resume a
      // partial removal before committing its record deletion.
      if fm.fileExists(atPath: source.path) { try fm.removeItem(at: source) }
      try write(next); dirty.removeAll()
    } else { throw LibraryFailure.app("library_records_recovery") }
    try fm.removeItem(at: journal)
    issue = nil; publish(invalidate: true)
  }
}

/// Local library mutations are serialized by PlayerBridge. Imports use isolated
/// staging directories and per-task cancellation so a stalled provider can be quarantined.
final class CourseLibrary {
  let root: URL
  let support: URL
  private let fm = FileManager.default
  private let protectionWork: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "雷player.protection"
    queue.qualityOfService = .utility
    queue.maxConcurrentOperationCount = 2
    return queue
  }()
  private let protectionSubmissionQueue = DispatchQueue(
    label: "雷player.protection.submit", qos: .utility)
  private let protectionLock = NSLock()
  private var pendingProtectionPaths: Set<String> = []
  let recordStore: LibraryRecordStore
  let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma", "ape", "alac", "ac3", "eac3", "dts"]
  let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "flv", "avi", "webm", "ts", "m2ts", "mts", "mpeg", "mpg", "3gp", "wmv", "vob"]

  init() throws {
    root = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .standardizedFileURL.resolvingSymlinksInPath()
    support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("LeiPlayer", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try fm.createDirectory(at: support, withIntermediateDirectories: true)
    try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
    recordStore = LibraryRecordStore(root: root, support: support)
  }

  /// Test-only-friendly initializer. Production continues to use the sandbox
  /// Documents/Application Support locations above.
  init(root: URL, support: URL) throws {
    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    self.support = support.standardizedFileURL.resolvingSymlinksInPath()
    try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
    try fm.createDirectory(at: self.support, withIntermediateDirectories: true)
    recordStore = LibraryRecordStore(root: self.root, support: self.support)
  }

  func url(_ path: String, allowRoot: Bool = false) throws -> URL {
    let candidate = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
    let base = root.standardizedFileURL.resolvingSymlinksInPath().path
    guard candidate.path.hasPrefix(base + "/") || (allowRoot && candidate.path == base) else {
      throw LibraryFailure.app("file_path_invalid")
    }
    return candidate
  }

  private func relativePath(_ file: URL, inside directory: URL) throws -> String {
    let base = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    let components = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    guard components.starts(with: base) else {
      throw LibraryFailure.app("library_path_invalid")
    }
    return components.dropFirst(base.count).joined(separator: "/")
  }

  func relative(_ url: URL) throws -> String {
    try relativePath(url, inside: root)
  }

  func normalizeProtection(path: String) throws {
    let file = try url(path)
    try fm.setAttributes([
      .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
    ], ofItemAtPath: file.path)
  }

  func scheduleProtectionNormalization(paths: [String]) {
    guard !paths.isEmpty else { return }
    // Keep the caller (normally the main thread after scan/open) O(1). Path
    // de-duplication and OperationQueue submission happen in one background batch.
    protectionSubmissionQueue.async { [weak self] in
      self?.enqueueProtectionNormalization(paths: paths)
    }
  }

  private func enqueueProtectionNormalization(paths: [String]) {
    for path in paths {
      protectionLock.lock()
      let inserted = pendingProtectionPaths.insert(path).inserted
      protectionLock.unlock()
      guard inserted else { continue }
      protectionWork.addOperation { [weak self] in
        guard let self = self else { return }
        defer {
          self.protectionLock.lock()
          self.pendingProtectionPaths.remove(path)
          self.protectionLock.unlock()
        }
        do { try self.normalizeProtection(path: path) }
        catch { NSLog("雷player: 文件保护属性更新失败 %@ %@", path, error.localizedDescription) }
      }
    }
  }

  /// Pure discovery: it does not normalize protection attributes or mutate
  /// records, so PlayerBridge may quarantine a timed-out scan safely.
  func scanSnapshot() throws -> LibraryScanSnapshot {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
    var warnings: [[String: Any]] = []
    var protectionPaths: [String] = []
    var protectionDirectories: [String] = []
    guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
        warnings.append([
          "code": "library_item_unreadable",
          "technicalDetail": error.localizedDescription,
        ])
        // A provider or damaged directory must not hide otherwise healthy items.
        return true
      }) else { throw LibraryFailure.app("library_read_failed") }
    var items: [[String: Any]] = []
    for case let file as URL in enumerator {
      do {
        if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
          warnings.append(["code": "symbolic_link_unsupported",
            "path": (try? relative(file)) ?? file.lastPathComponent])
          enumerator.skipDescendants()
          continue
        }
        let values = try file.resourceValues(forKeys: Set(keys))
        let directory = values.isDirectory == true
        let ext = file.pathExtension.lowercased()
        let type = directory ? "folder" : videoExtensions.contains(ext) ? "video" : audioExtensions.contains(ext) ? "audio" : ["srt", "vtt", "ass", "ssa", "sup"].contains(ext) ? "subtitle" : "other"
        let path = try relative(file)
        // Derive parent from the same relative path consumed by Flutter.
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        items.append(["path": path, "name": file.lastPathComponent,
          "parent": parent,
          "kind": type, "size": values.fileSize ?? 0,
          "modified": values.contentModificationDate?.timeIntervalSince1970 ?? 0])
        if directory { protectionDirectories.append(path) }
        else if type == "video" || type == "audio" || type == "subtitle" {
          protectionPaths.append(path)
        }
      } catch {
        warnings.append(["code": "library_item_unreadable",
          "path": (try? relative(file)) ?? file.lastPathComponent,
          "technicalDetail": error.localizedDescription])
        if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
          enumerator.skipDescendants()
        }
      }
    }
    var folderSizes: [String: Int] = [:]
    for item in items where item["kind"] as? String != "folder" {
      let size = item["size"] as? Int ?? 0
      var parent = item["parent"] as? String ?? ""
      while !parent.isEmpty {
        folderSizes[parent, default: 0] += size
        guard let separator = parent.lastIndex(of: "/") else { break }
        parent = String(parent[..<separator])
      }
    }
    for index in items.indices where items[index]["kind"] as? String == "folder" {
      let path = items[index]["path"] as? String ?? ""
      items[index]["size"] = folderSizes[path] ?? 0
    }
    let sorted = items.sorted {
      ($0["path"] as! String).localizedStandardCompare($1["path"] as! String) == .orderedAscending
    }
    return LibraryScanSnapshot(items: sorted, warnings: warnings,
      protectionPaths: protectionPaths + protectionDirectories)
  }

  func validName(_ name: String) throws -> String {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, clean != ".", clean != "..", !clean.hasPrefix("."),
      !clean.contains("/"), !clean.contains(":"), !clean.contains("\0"), clean.utf8.count < 240 else {
      throw LibraryFailure.app("invalid_file_name")
    }
    return clean
  }

  func createFolder(parent: String, name: String) throws {
    let target = try url(parent, allowRoot: true).appendingPathComponent(validName(name))
    guard !fm.fileExists(atPath: target.path) else { throw LibraryFailure.app("duplicate_item") }
    try fm.createDirectory(at: target, withIntermediateDirectories: false,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
  }

  func move(path: String, parent: String, name: String) throws -> String {
    let source = try url(path)
    let destination = try url(parent, allowRoot: true).appendingPathComponent(validName(name)).standardizedFileURL
    guard destination != source, !destination.path.hasPrefix(source.path + "/") else {
      throw LibraryFailure.app("invalid_move_destination")
    }
    guard !fm.fileExists(atPath: destination.path) else { throw LibraryFailure.app("destination_duplicate_item") }
    let new = try relative(destination)
    do {
      try recordStore.fileMutation(kind: "move", source: source, destination: destination) { records in
        for key in Array(records.keys) where key == path || key.hasPrefix(path + "/") {
          records[new + String(key.dropFirst(path.count))] = records.removeValue(forKey: key)
        }
      }
    } catch {
      if !fm.fileExists(atPath: source.path), fm.fileExists(atPath: destination.path) {
        throw LibraryFailure.app("library_records_recovery", args: ["movedPath": new], technicalDetail: error.localizedDescription)
      }
      throw error
    }
    return new
  }

  func trash(path: String) throws -> String {
    let source = try url(path)
    let token = UUID().uuidString
    let directory = support.appendingPathComponent("Trash/" + token, isDirectory: true)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      try Data(path.utf8).write(to: directory.appendingPathComponent("original.txt"), options: .atomic)
      try Data(String(Date().timeIntervalSince1970).utf8)
        .write(to: directory.appendingPathComponent("deletedAt.txt"), options: .atomic)
      try recordStore.fileMutation(kind: "move", source: source,
        destination: directory.appendingPathComponent("content")) { _ in }
      return token
    } catch {
      // A failed post-move record commit still owns the recoverable content.
      if !fm.fileExists(atPath: directory.appendingPathComponent("content").path),
        recordStore.status != "library_records_recovery" { try? fm.removeItem(at: directory) }
      if fm.fileExists(atPath: directory.appendingPathComponent("content").path), !fm.fileExists(atPath: source.path) {
        throw LibraryFailure.app("library_records_recovery", args: ["fileChanged": true], technicalDetail: error.localizedDescription)
      }
      throw error
    }
  }

  func restore(token: String) throws {
    guard UUID(uuidString: token) != nil else { throw LibraryFailure.app("restore_token_invalid") }
    let directory = support.appendingPathComponent("Trash/" + token)
    let path = try String(contentsOf: directory.appendingPathComponent("original.txt"), encoding: .utf8)
    let target = try url(path)
    guard !fm.fileExists(atPath: target.path) else { throw LibraryFailure.app("restore_destination_exists") }
    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try recordStore.fileMutation(kind: "move", source: directory.appendingPathComponent("content"),
      destination: target) { _ in }
    try? fm.removeItem(at: directory)
  }

  func trashList() throws -> [[String: Any]] {
    let directory = support.appendingPathComponent("Trash")
    guard fm.fileExists(atPath: directory.path) else { return [] }
    let items = try fm.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey])
    let entries: [[String: Any]] = items.map { item in
      let path = try? String(contentsOf: item.appendingPathComponent("original.txt"), encoding: .utf8)
      let storedTime = (try? String(contentsOf: item.appendingPathComponent("deletedAt.txt"), encoding: .utf8))
        .flatMap(Double.init)
      let values = try? item.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
      let deletedAt = storedTime ?? values?.creationDate?.timeIntervalSince1970
        ?? values?.contentModificationDate?.timeIntervalSince1970 ?? 0
      let recoverable = UUID(uuidString: item.lastPathComponent) != nil
        && path.flatMap({ try? url($0) }) != nil
        && fm.fileExists(atPath: item.appendingPathComponent("content").path)
      return ["token": item.lastPathComponent, "path": path ?? "", "deletedAt": deletedAt,
        "recoverable": recoverable]
    }
    return entries.sorted {
      ($0["deletedAt"] as? Double ?? 0) > ($1["deletedAt"] as? Double ?? 0)
    }
  }

  func emptyTrash() throws {
    let directory = support.appendingPathComponent("Trash")
    guard fm.fileExists(atPath: directory.path) else { return }
    for item in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
      guard UUID(uuidString: item.lastPathComponent) != nil else { continue }
      let path = try? String(contentsOf: item.appendingPathComponent("original.txt"), encoding: .utf8)
      try recordStore.fileMutation(kind: "purge", source: item, destination: nil) { records in
        guard let path = path, let original = try? self.url(path),
          !self.fm.fileExists(atPath: original.path) else { return }
        for key in Array(records.keys) where key == path || key.hasPrefix(path + "/") {
          // Do not delete records of a new file imported at the same path.
          if !self.fm.fileExists(atPath: self.root.appendingPathComponent(key).path) { records.removeValue(forKey: key) }
        }
      }
    }
  }

  func beginImport() -> ImportCancellation { ImportCancellation() }
  func cancelImport(_ cancellation: ImportCancellation) { cancellation.cancel() }
  private func checkCancellation(_ cancellation: ImportCancellation) throws {
    if cancellation.isCancelled { throw LibraryFailure.app("import_cancelled") }
  }

  /// Stage each selection outside Documents; only complete selections become visible.
  func importFiles(_ sources: [URL], parent: String, cancellation: ImportCancellation,
                   skipped: @escaping (String) -> Void = { _ in },
                   progress: @escaping (String, Int64, Int64) -> Void) throws -> [String] {
    let destination = try url(parent, allowRoot: true)
    let staging = support.appendingPathComponent("Import-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }
    var imported: [String] = []
    for source in sources {
      try checkCancellation(cancellation)
      let accessible = source.startAccessingSecurityScopedResource()
      defer { if accessible { source.stopAccessingSecurityScopedResource() } }
      var coordinationError: NSError?
      var operationError: Error?
      NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
        do {
          try self.checkCancellation(cancellation)
          var directoryFlag: ObjCBool = false
          guard self.fm.fileExists(atPath: coordinated.path, isDirectory: &directoryFlag) else {
            throw LibraryFailure.app("selected_file_unavailable")
          }
          let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
          guard try coordinated.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw LibraryFailure.app("symbolic_link_unsupported")
          }
          var files: [URL] = []
          if directoryFlag.boolValue {
            var enumerationError: Error?
            let enumerator = self.fm.enumerator(at: coordinated, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false })
            while let file = enumerator?.nextObject() as? URL {
              try self.checkCancellation(cancellation)
              let values = try file.resourceValues(forKeys: keys)
              if values.isSymbolicLink == true {
                // Use the lexical relative name; resolving a link may leave the source root.
                skipped(source.lastPathComponent + "/" + file.pathComponents.dropFirst(coordinated.pathComponents.count).joined(separator: "/"))
                enumerator?.skipDescendants(); continue
              }
              files.append(file)
            }
            if let error = enumerationError { throw error }
          } else { files = [coordinated] }
          var total: Int64 = 0
          for file in files { total += Int64(try file.resourceValues(forKeys: keys).fileSize ?? 0) }
          let capacity = try destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
          if let capacity = capacity, total + 32 * 1024 * 1024 > capacity {
            throw LibraryFailure.app("storage_insufficient", args: ["requiredMB": total / 1024 / 1024])
          }
          let staged = staging.appendingPathComponent("selection")
          if directoryFlag.boolValue { try self.fm.createDirectory(at: staged, withIntermediateDirectories: true) }
          var completed: Int64 = 0
          var lastProgress = Date.distantPast
          for file in files {
            try self.checkCancellation(cancellation)
            let relative: String
            if directoryFlag.boolValue { relative = try self.relativePath(file, inside: coordinated) }
            else { relative = "" }
            let target = relative.isEmpty ? staged : staged.appendingPathComponent(relative)
            let values = try file.resourceValues(forKeys: keys)
            if values.isDirectory == true {
              try self.fm.createDirectory(at: target, withIntermediateDirectories: true)
              continue
            }
            try self.fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let input = InputStream(url: file), let output = OutputStream(url: target, append: false) else { throw LibraryFailure.app("import_file_open_failed") }
            input.open(); output.open()
            defer { input.close(); output.close() }
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while true {
              try self.checkCancellation(cancellation)
              let count = input.read(&buffer, maxLength: buffer.count)
              if count == 0 { break }
              if count < 0 { throw input.streamError ?? LibraryFailure.app("import_read_failed") }
              var written = 0
              while written < count {
                let amount = buffer.withUnsafeBufferPointer { output.write($0.baseAddress! + written, maxLength: count - written) }
                if amount <= 0 { throw output.streamError ?? LibraryFailure.app("import_write_failed") }
                written += amount
              }
              completed += Int64(count)
              if Date().timeIntervalSince(lastProgress) > 0.15 {
                progress(source.lastPathComponent, completed, total); lastProgress = Date()
              }
            }
            try self.fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
          }
          try self.checkCancellation(cancellation)
          var target = destination.appendingPathComponent(source.lastPathComponent)
          var suffix = 2
          while self.fm.fileExists(atPath: target.path) {
            let ext = source.pathExtension
            let stem = directoryFlag.boolValue ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
            target = destination.appendingPathComponent("\(stem) (\(suffix))" + (directoryFlag.boolValue || ext.isEmpty ? "" : "." + ext))
            suffix += 1
          }
          try self.fm.moveItem(at: staged, to: target)
          progress(source.lastPathComponent, total, total)
          imported.append(try self.relative(target))
        } catch { operationError = error }
      }
      if let error = coordinationError { throw error }
      if let error = operationError {
        let failure = error as? LibraryFailure
        throw LibraryFailure.app(
          "import_partial_failure",
          args: [
            "completed": imported.count,
            "reasonCode": failure?.code ?? "operation_failed",
            "reasonArgs": failure?.args ?? [:],
          ],
          technicalDetail: failure?.technicalDetail ?? error.localizedDescription)
      }
    }
    return imported
  }
}
