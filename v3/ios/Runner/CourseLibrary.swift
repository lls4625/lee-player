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

/// Local library mutations are serialized by PlayerBridge. Imports use isolated
/// staging directories and per-task cancellation so a stalled provider can be quarantined.
final class CourseLibrary {
  let root: URL
  let support: URL
  private let fm = FileManager.default
  var records: [String: [String: Any]] = [:]
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
    if let data = try? Data(contentsOf: support.appendingPathComponent("library.json")),
       let value = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
      records = value
    }
  }

  func save() {
    do {
      let data = try JSONSerialization.data(withJSONObject: records)
      try data.write(to: support.appendingPathComponent("library.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch { NSLog("雷player: 保存记录失败 %@", error.localizedDescription) }
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

  func scan() throws -> [[String: Any]] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
    var scanError: Error?
    guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
        scanError = error; return false
      }) else { throw LibraryFailure.app("library_read_failed") }
    var items: [[String: Any]] = []
    for case let file as URL in enumerator {
      let values = try file.resourceValues(forKeys: Set(keys))
      if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
      let directory = values.isDirectory == true
      let ext = file.pathExtension.lowercased()
      let type = directory ? "folder" : videoExtensions.contains(ext) ? "video" : audioExtensions.contains(ext) ? "audio" : ["srt", "vtt", "ass", "ssa", "sup"].contains(ext) ? "subtitle" : "other"
      // Finder / Files transfers also need to remain readable across screen locking.
      if directory || type == "video" || type == "audio" || type == "subtitle" {
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
      }
      let path = try relative(file)
      // Derive parent from the same relative path consumed by Flutter.
      let parent = path.split(separator: "/").dropLast().joined(separator: "/")
      items.append(["path": path, "name": file.lastPathComponent,
        "parent": parent,
        "kind": type, "size": values.fileSize ?? 0,
        "modified": values.contentModificationDate?.timeIntervalSince1970 ?? 0])
    }
    if let error = scanError { throw error }
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
    return items.sorted {
      ($0["path"] as! String).localizedStandardCompare($1["path"] as! String) == .orderedAscending
    }
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
    try fm.moveItem(at: source, to: destination)
    return try relative(destination)
  }

  func remapRecords(from old: String, to new: String) {
    for key in Array(records.keys) where key == old || key.hasPrefix(old + "/") {
      records[new + String(key.dropFirst(old.count))] = records.removeValue(forKey: key)
    }
    save()
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
      try fm.moveItem(at: source, to: directory.appendingPathComponent("content"))
      return token
    } catch { try? fm.removeItem(at: directory); throw error }
  }

  func restore(token: String) throws {
    guard UUID(uuidString: token) != nil else { throw LibraryFailure.app("restore_token_invalid") }
    let directory = support.appendingPathComponent("Trash/" + token)
    let path = try String(contentsOf: directory.appendingPathComponent("original.txt"), encoding: .utf8)
    let target = try url(path)
    guard !fm.fileExists(atPath: target.path) else { throw LibraryFailure.app("restore_destination_exists") }
    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.moveItem(at: directory.appendingPathComponent("content"), to: target)
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
    let deletedPaths = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
      .compactMap { item -> String? in
        guard let path = try? String(contentsOf: item.appendingPathComponent("original.txt"), encoding: .utf8),
          (try? url(path)) != nil else { return nil }
        return path
      } ?? []
    try fm.removeItem(at: directory)
    var recordsChanged = false
    for key in Array(records.keys)
      where deletedPaths.contains(where: { key == $0 || key.hasPrefix($0 + "/") }) {
      records.removeValue(forKey: key)
      recordsChanged = true
    }
    if recordsChanged { save() }
  }

  func beginImport() -> ImportCancellation { ImportCancellation() }
  func cancelImport(_ cancellation: ImportCancellation) { cancellation.cancel() }
  private func checkCancellation(_ cancellation: ImportCancellation) throws {
    if cancellation.isCancelled { throw LibraryFailure.app("import_cancelled") }
  }

  /// Stage each selection outside Documents; only complete selections become visible.
  func importFiles(_ sources: [URL], parent: String, cancellation: ImportCancellation,
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
              if values.isSymbolicLink == true { enumerator?.skipDescendants(); continue }
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
