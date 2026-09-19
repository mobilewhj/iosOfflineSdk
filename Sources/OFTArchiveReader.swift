import Foundation

/// Internal ObjC bridge. ZIPFoundation 0.9.20 sources are compiled in this target.
@objc(OFTArchiveReader)
public final class OFTArchiveReader: NSObject {
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "com.offline.tool", code: 7,
                userInfo: [NSLocalizedDescriptionKey: message, "stage": "extract"])
    }

    @objc(extractArchive:toDirectory:cancellation:progress:error:)
    public static func extract(archiveURL: URL, toDirectory destination: URL, cancellation: Progress,
                        progress: (Int64, Int64) -> Void) throws {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        guard archive.totalNumberOfEntriesInCentralDirectory > 0,
              archive.totalNumberOfEntriesInCentralDirectory <= 10_000 else {
            throw failure("归档条目数量无效或超过 10000")
        }
        var entries: [(Entry, String)] = []
        var paths: [String: Entry.EntryType] = [:]
        var declared: UInt64 = 0
        for entry in archive {
            if cancellation.isCancelled { throw failure("资源解压已取消") }
            guard entries.count < 10_000, entry.type != .symlink else { throw failure("归档包含链接或条目超限") }
            let path = entry.path
            let name = entry.type == .directory && path.hasSuffix("/") ? String(path.dropLast()) : path
            guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
                  !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  !name.components(separatedBy: "/").contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw failure("归档包含非法路径")
            }
            // Reject case/Unicode aliases on both case-sensitive and insensitive filesystems.
            let key = name.precomposedStringWithCanonicalMapping.lowercased()
            guard paths[key] == nil else { throw failure("归档包含重复路径") }
            paths[key] = entry.type
            guard entry.uncompressedSize <= 64 * 1024 * 1024 else { throw failure("单文件超过 64 MiB") }
            declared += entry.uncompressedSize
            guard declared <= 256 * 1024 * 1024 else { throw failure("解压总大小超过 256 MiB") }
            entries.append((entry, name))
        }
        guard UInt64(entries.count) == archive.totalNumberOfEntriesInCentralDirectory else { throw failure("归档目录不完整") }
        for (_, name) in entries {
            var components = name.precomposedStringWithCanonicalMapping.lowercased().components(separatedBy: "/")
            components.removeLast()
            while !components.isEmpty {
                if let type = paths[components.joined(separator: "/")], type != .directory { throw failure("归档文件与目录冲突") }
                components.removeLast()
            }
        }
        let fm = FileManager.default
        var actual: Int64 = 0
        for (entry, name) in entries {
            if cancellation.isCancelled { throw failure("资源解压已取消") }
            let target = destination.appendingPathComponent(name)
            if entry.type == .directory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Newly created private staging directory, validated paths, no symlink entries.
            guard fm.createFile(atPath: target.path, contents: nil), let output = OutputStream(url: target, append: false) else {
                throw failure("无法创建解压文件")
            }
            output.open()
            defer { output.close() }
            var fileBytes: Int64 = 0
            let crc = try archive.extract(entry, bufferSize: 64 * 1024) { data in
                if cancellation.isCancelled { throw failure("资源解压已取消") }
                fileBytes += Int64(data.count); actual += Int64(data.count)
                guard fileBytes <= 64 * 1024 * 1024, actual <= 256 * 1024 * 1024,
                      UInt64(fileBytes) <= entry.uncompressedSize else { throw failure("实际解压大小超过限制") }
                try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                    guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    var offset = 0
                    while offset < data.count {
                        let written = output.write(base.advanced(by: offset), maxLength: data.count - offset)
                        guard written > 0 else { throw output.streamError ?? failure("解压文件写入失败") }
                        offset += written
                    }
                }
                progress(actual, Int64(declared))
            }
            guard crc == entry.checksum, UInt64(fileBytes) == entry.uncompressedSize else { throw failure("归档内容校验失败") }
        }
    }
}
