import Foundation
import Darwin

/// 内部 ObjC 桥接，复用同一编译目标中的 ZIPFoundation 0.9.20。
@objc(OFTArchiveReader)
public final class OFTArchiveReader: NSObject {
    private static func failure(_ message: String, tooLarge: Bool = false) -> NSError {
        NSError(domain: "com.offline.tool", code: tooLarge ? 5 : 7,
                userInfo: [NSLocalizedDescriptionKey: message, "stage": "extract"])
    }

    private static func fileFailure(_ message: String) -> NSError {
        NSError(domain: "com.offline.tool", code: 2, userInfo: [NSLocalizedDescriptionKey: message, "stage": "extract"])
    }

    @objc(extractArchive:toDirectory:cancellation:progress:error:)
    public static func extract(archiveURL: URL, toDirectory destination: URL, cancellation: Progress,
                        progress: (Int64, Int64) -> Void) throws {
        try extract(archiveURL: archiveURL, destination: destination, cancellation: cancellation, limited: true, progress: progress)
    }

    @objc(extractManagedArchive:toDirectory:cancellation:progress:error:)
    public static func extractManaged(archiveURL: URL, toDirectory destination: URL, cancellation: Progress,
                                      progress: (Int64, Int64) -> Void) throws {
        try extract(archiveURL: archiveURL, destination: destination, cancellation: cancellation, limited: false, progress: progress)
    }

    private static func extract(archiveURL: URL, destination: URL, cancellation: Progress, limited: Bool,
                                progress: (Int64, Int64) -> Void) throws {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        guard archive.totalNumberOfEntriesInCentralDirectory > 0 else { throw failure("归档条目数量无效") }
        guard !limited || archive.totalNumberOfEntriesInCentralDirectory <= 10_000 else { throw failure("归档条目超过 10000", tooLarge: true) }
        var entries: [(Entry, String)] = []
        var paths: [String: Entry.EntryType] = [:]
        var declared: UInt64 = 0
        var centralBytes: UInt64 = 0
        for entry in archive {
            if cancellation.isCancelled { throw failure("资源解压已取消") }
            guard !limited || entries.count < 10_000 else { throw failure("归档条目超过 10000", tooLarge: true) }
            guard entry.type != .symlink else { throw failure("归档包含链接") }
            let central = entry.centralDirectoryStructure
            let local = entry.localFileHeader
            // 库的目录分支不读取负载，先核对真实的本地头与中央目录。
            guard central.fileNameData == local.fileNameData,
                  central.generalPurposeBitFlag == local.generalPurposeBitFlag,
                  central.compressionMethod == local.compressionMethod else { throw failure("归档本地头与中央目录不一致") }
            if !central.usesDataDescriptor {
                guard local.crc32 == central.crc32,
                      (local.uncompressedSize == UInt32.max || UInt64(local.uncompressedSize) == central.effectiveUncompressedSize),
                      (local.compressedSize == UInt32.max || UInt64(local.compressedSize) == central.effectiveCompressedSize) else {
                    throw failure("归档大小或校验字段不一致")
                }
            } else {
                guard (entry.dataDescriptor != nil || entry.zip64DataDescriptor != nil),
                      entry.uncompressedSize == central.effectiveUncompressedSize,
                      entry.compressedSize == central.effectiveCompressedSize,
                      entry.checksum == central.crc32 else { throw failure("归档数据描述符不一致") }
            }
            guard entry.dataOffset <= archive.offsetToStartOfCentralDirectory,
                  entry.compressedSize <= archive.offsetToStartOfCentralDirectory - entry.dataOffset else {
                throw failure("归档负载越过中央目录")
            }
            centralBytes += UInt64(Entry.CentralDirectoryStructure.size) + UInt64(central.fileNameLength) +
                            UInt64(central.extraFieldLength) + UInt64(central.fileCommentLength)
            let path = entry.path
            let name = entry.type == .directory && path.hasSuffix("/") ? String(path.dropLast()) : path
            guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
                  !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  !name.components(separatedBy: "/").contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                throw failure("归档包含非法路径")
            }
            // 在不同文件系统上统一拒绝大小写与 Unicode 别名。
            let key = name.precomposedStringWithCanonicalMapping.lowercased()
            guard paths[key] == nil else { throw failure("归档包含重复路径") }
            paths[key] = entry.type
            guard !limited || entry.uncompressedSize <= 64 * 1024 * 1024 else { throw failure("单文件超过 64 MiB", tooLarge: true) }
            if entry.type == .directory {
                guard entry.uncompressedSize == 0, central.effectiveUncompressedSize == 0,
                      local.uncompressedSize == 0, central.crc32 == 0, local.crc32 == 0 else { throw failure("归档目录包含负载") }
            }
            guard entry.uncompressedSize <= UInt64(Int64.max) - declared else { throw failure("Archive size overflow") }
            declared += entry.uncompressedSize
            guard !limited || declared <= 256 * 1024 * 1024 else { throw failure("解压总大小超过 256 MiB", tooLarge: true) }
            entries.append((entry, name))
        }
        guard UInt64(entries.count) == archive.totalNumberOfEntriesInCentralDirectory,
              centralBytes == archive.sizeOfCentralDirectory else { throw failure("归档目录不完整") }
        for (_, name) in entries {
            var components = name.precomposedStringWithCanonicalMapping.lowercased().components(separatedBy: "/")
            components.removeLast()
            while !components.isEmpty {
                if let type = paths[components.joined(separator: "/")], type != .directory { throw failure("归档文件与目录冲突") }
                components.removeLast()
            }
        }
        let fm = FileManager.default
        let stripDist = !limited && !entries.contains(where: { $0.1 == "index.html" }) && entries.contains(where: { $0.1 == "dist/index.html" })
        var actual: Int64 = 0
        for (entry, storedName) in entries {
            let name: String
            if stripDist {
                guard storedName.hasPrefix("dist/") else { continue }
                name = String(storedName.dropFirst(5))
            } else { name = storedName }
            if cancellation.isCancelled { throw failure("资源解压已取消") }
            let target = destination.appendingPathComponent(name)
            if entry.type == .directory {
                // 空目录允许正常 deflate 表示，但不能仅靠声明大小隐藏实际解压数据。
                fseeko(archive.archiveFile, off_t(entry.dataOffset), SEEK_SET)
                let rejectPayload: Consumer = { data in
                    if cancellation.isCancelled { throw failure("资源解压已取消") }
                    if !data.isEmpty { throw failure("归档目录包含实际负载") }
                }
                switch CompressionMethod(rawValue: entry.localFileHeader.compressionMethod) {
                case .some(.none):
                    guard entry.compressedSize == 0 else { throw failure("归档目录负载大小无效") }
                case .some(.deflate):
                    let crc = try archive.readCompressed(entry: entry, bufferSize: 64 * 1024, skipCRC32: false, with: rejectPayload)
                    guard crc == 0 else { throw failure("归档目录校验失败") }
                default: throw failure("归档目录压缩方式无效")
                }
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Managed extraction must confirm file writes before ready can be persisted.
            var descriptor = Darwin.open(target.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw fileFailure("Cannot create extraction output") }
            defer { if descriptor >= 0 { Darwin.close(descriptor) } }
            var fileBytes: Int64 = 0
            let crc = try archive.extract(entry, bufferSize: 64 * 1024) { data in
                if cancellation.isCancelled { throw failure("资源解压已取消") }
                guard data.count <= Int64.max - actual, data.count <= Int64.max - fileBytes else { throw failure("Archive size overflow") }
                fileBytes += Int64(data.count); actual += Int64(data.count)
                guard !limited || (fileBytes <= 64 * 1024 * 1024 && actual <= 256 * 1024 * 1024) else { throw failure("实际解压大小超过限制", tooLarge: true) }
                guard UInt64(fileBytes) <= entry.uncompressedSize else { throw failure("实际解压大小与声明不一致") }
                try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                    guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    var offset = 0
                    while offset < data.count {
                        let written = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw fileFailure("Extraction output write failed") }
                        offset += written
                    }
                }
                progress(actual, Int64(declared))
            }
            guard crc == entry.checksum, UInt64(fileBytes) == entry.uncompressedSize else { throw failure("归档内容校验失败") }
            var synced: Int32
            repeat { synced = Darwin.fsync(descriptor) } while synced < 0 && errno == EINTR
            guard synced == 0 else { throw fileFailure("Extraction output sync failed") }
            let closed = Darwin.close(descriptor)
            descriptor = -1
            guard closed == 0 else { throw fileFailure("Extraction output close failed") }
        }
    }
}
