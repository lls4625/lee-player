import Foundation

enum LibraryFailure: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let text) = self { return text }
    return nil
  }
}

/// All filesystem work is serialized by PlayerBridge; UI metadata is main-thread owned.
final class CourseLibrary {
  let root: URL
  let support: URL
  private let fm = FileManager.default
  private let cancellation = NSLock()
  private var cancelled = false
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
      throw LibraryFailure.message("文件路径无效")
    }
    return candidate
  }

  private func relativePath(_ file: URL, inside directory: URL) throws -> String {
    let base = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    let components = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    guard components.starts(with: base) else {
      throw LibraryFailure.message("文件不在指定目录内，无法生成课程路径")
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
      }) else { throw LibraryFailure.message("无法读取课程目录") }
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
      throw LibraryFailure.message("名称不能为空，不能包含 /、: 或以点开头")
    }
    return clean
  }

  func createFolder(parent: String, name: String) throws {
    let target = try url(parent, allowRoot: true).appendingPathComponent(validName(name))
    guard !fm.fileExists(atPath: target.path) else { throw LibraryFailure.message("同名项目已存在") }
    try fm.createDirectory(at: target, withIntermediateDirectories: false,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
  }

  func move(path: String, parent: String, name: String) throws -> String {
    let source = try url(path)
    let destination = try url(parent, allowRoot: true).appendingPathComponent(validName(name)).standardizedFileURL
    guard destination != source, !destination.path.hasPrefix(source.path + "/") else {
      throw LibraryFailure.message("不能移到原位置或自己的子目录")
    }
    guard !fm.fileExists(atPath: destination.path) else { throw LibraryFailure.message("目标中已有同名项目") }
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
    guard UUID(uuidString: token) != nil else { throw LibraryFailure.message("恢复标识无效") }
    let directory = support.appendingPathComponent("Trash/" + token)
    let path = try String(contentsOf: directory.appendingPathComponent("original.txt"), encoding: .utf8)
    let target = try url(path)
    guard !fm.fileExists(atPath: target.path) else { throw LibraryFailure.message("原位置已有同名文件，请先改名") }
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

  func beginImport() { cancellation.lock(); cancelled = false; cancellation.unlock() }
  func cancelImport() { cancellation.lock(); cancelled = true; cancellation.unlock() }
  private func checkCancellation() throws {
    cancellation.lock(); let value = cancelled; cancellation.unlock()
    if value { throw LibraryFailure.message("已取消导入，未完成的文件已清理") }
  }

  /// Stage each selection outside Documents; only complete selections become visible.
  func importFiles(_ sources: [URL], parent: String, progress: @escaping (String, Int64, Int64) -> Void) throws -> [String] {
    let destination = try url(parent, allowRoot: true)
    let staging = support.appendingPathComponent("Import-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }
    var imported: [String] = []
    for source in sources {
      try checkCancellation()
      let accessible = source.startAccessingSecurityScopedResource()
      defer { if accessible { source.stopAccessingSecurityScopedResource() } }
      var coordinationError: NSError?
      var operationError: Error?
      NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
        do {
          var directoryFlag: ObjCBool = false
          guard self.fm.fileExists(atPath: coordinated.path, isDirectory: &directoryFlag) else {
            throw LibraryFailure.message("所选文件不可用，请先下载到本机")
          }
          let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
          guard try coordinated.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw LibraryFailure.message("不能导入符号链接，请选择原文件")
          }
          var files: [URL] = []
          if directoryFlag.boolValue {
            var enumerationError: Error?
            let enumerator = self.fm.enumerator(at: coordinated, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: { _, error in enumerationError = error; return false })
            while let file = enumerator?.nextObject() as? URL {
              try self.checkCancellation()
              let values = try file.resourceValues(forKeys: keys)
              if values.isSymbolicLink == true { enumerator?.skipDescendants(); continue }
              files.append(file)
            }
            if let error = enumerationError { throw error }
          } else { files = [coordinated] }
          var total: Int64 = 0
          for file in files { total += Int64(try file.resourceValues(forKeys: keys).fileSize ?? 0) }
          let capacity = try destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
          if let capacity = capacity, total + 32 * 1024 * 1024 > capacity { throw LibraryFailure.message("剩余空间不足，导入需要约 \(total / 1024 / 1024) MB") }
          let staged = staging.appendingPathComponent("selection")
          if directoryFlag.boolValue { try self.fm.createDirectory(at: staged, withIntermediateDirectories: true) }
          var completed: Int64 = 0
          var lastProgress = Date.distantPast
          for file in files {
            try self.checkCancellation()
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
            guard let input = InputStream(url: file), let output = OutputStream(url: target, append: false) else { throw LibraryFailure.message("无法打开导入文件") }
            input.open(); output.open()
            defer { input.close(); output.close() }
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while true {
              try self.checkCancellation()
              let count = input.read(&buffer, maxLength: buffer.count)
              if count == 0 { break }
              if count < 0 { throw input.streamError ?? LibraryFailure.message("读取失败") }
              var written = 0
              while written < count {
                let amount = buffer.withUnsafeBufferPointer { output.write($0.baseAddress! + written, maxLength: count - written) }
                if amount <= 0 { throw output.streamError ?? LibraryFailure.message("写入失败，请检查存储空间") }
                written += amount
              }
              completed += Int64(count)
              if Date().timeIntervalSince(lastProgress) > 0.15 {
                progress(source.lastPathComponent, completed, total); lastProgress = Date()
              }
            }
            try self.fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
          }
          try self.checkCancellation()
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
      if let error = operationError { throw LibraryFailure.message("\(error.localizedDescription)；此前已完成 \(imported.count) 项") }
    }
    return imported
  }
}
