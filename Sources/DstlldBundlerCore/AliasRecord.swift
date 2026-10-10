//
//  AliasRecord.swift
//  DstlldBundlerCore
//
//  A classic Mac OS alias record (version 2), the way a `.DS_Store` names a window's background
//  picture. Finder finds the picture again by the volume's name and creation date, the file's
//  catalogue ids, and the paths in the tagged fields after the fixed part, so those are taken from
//  the mounted disk image, not guessed.
//
//  The fixed part is 150 bytes. Tagged fields follow, each a 16-bit tag, a 16-bit length and the
//  data padded to an even length; tag -1 ends the record. The layout follows Apple's old
//  `Aliases.h` and dmgbuild's `mac_alias`.
//

import Foundation

public struct AliasRecord: Sendable, Equatable {
    public var volumeName: String
    public var volumeCreated: Date
    /// Where the volume will be mounted when someone opens the disk image: `/Volumes/<name>`.
    public var volumeMountPoint: String
    public var parentID: UInt32
    public var parentName: String
    public var fileID: UInt32
    public var fileName: String
    public var fileCreated: Date
    /// The file's path from the volume's root, starting with `/`.
    public var pathInVolume: String

    public init(
        volumeName: String, volumeCreated: Date, volumeMountPoint: String, parentID: UInt32, parentName: String,
        fileID: UInt32, fileName: String, fileCreated: Date, pathInVolume: String
    ) {
        self.volumeName = volumeName
        self.volumeCreated = volumeCreated
        self.volumeMountPoint = volumeMountPoint
        self.parentID = parentID
        self.parentName = parentName
        self.fileID = fileID
        self.fileName = fileName
        self.fileCreated = fileCreated
        self.pathInVolume = pathInVolume
    }

    /// The alias for `file`, a file inside the volume mounted at `mountPoint`.
    ///
    /// - Parameter publicMountPoint: where Finder will mount the volume later, which can differ
    ///   from where it is mounted now.
    public static func `for`(file: URL, onVolumeAt mountPoint: URL, publicMountPoint: String) throws(BundlerError)
        -> AliasRecord
    {
        let parent = file.deletingLastPathComponent()
        do {
            let volume = try mountPoint.resourceValues(forKeys: [.volumeNameKey, .volumeCreationDateKey])
            let fileValues = try file.resourceValues(forKeys: [.creationDateKey])
            guard let volumeName = volume.volumeName, let volumeCreated = volume.volumeCreationDate,
                let fileCreated = fileValues.creationDate
            else {
                throw BundlerError("the disk image's volume did not report its name and creation date")
            }
            let root = mountPoint.standardizedFileURL.path
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else {
                throw BundlerError("\(file.lastPathComponent) is not on the disk image's volume")
            }
            return AliasRecord(
                volumeName: volumeName, volumeCreated: volumeCreated, volumeMountPoint: publicMountPoint,
                parentID: try inode(parent), parentName: parent.lastPathComponent,
                fileID: try inode(file), fileName: file.lastPathComponent, fileCreated: fileCreated,
                pathInVolume: String(path.dropFirst(root.count)))
        } catch let error as BundlerError {
            throw error
        } catch {
            throw BundlerError("could not describe the disk image's background: \(error.localizedDescription)")
        }
    }

    private static func inode(_ url: URL) throws(BundlerError) -> UInt32 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw BundlerError("could not read \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        // Catalogue node ids on a fresh disk image are small; HFS+ and the alias format keep 32 bits.
        return UInt32(truncatingIfNeeded: info.st_ino)
    }

    /// The record's bytes.
    public var data: Data {
        var record = Data()
        record.append(Data(count: 4))  // application information, unused
        record.appendUInt16(0)  // the record's size, filled in last
        record.appendUInt16(2)  // version
        record.appendUInt16(0)  // kind: a file
        record.appendPascalString(volumeName, capacity: 27)
        record.appendUInt32(Self.hfsSeconds(volumeCreated))
        record.append(contentsOf: Array("H+".utf8))  // volume signature
        record.appendUInt16(0)  // volume type: a fixed disk
        record.appendUInt32(parentID)
        record.appendPascalString(fileName, capacity: 63)
        record.appendUInt32(fileID)
        record.appendUInt32(Self.hfsSeconds(fileCreated))
        record.append(Data(count: 8))  // file type and creator
        record.appendUInt16(0xFFFF)  // levels from the alias to the common ancestor: unknown
        record.appendUInt16(0xFFFF)  // and from the target: unknown
        record.appendUInt32(0)  // volume attributes
        record.appendUInt16(0)  // volume file-system id
        record.append(Data(count: 10))  // reserved
        precondition(record.count == 150, "an alias record's fixed part is 150 bytes")

        let carbonPath = ([volumeName] + pathInVolume.split(separator: "/").map(String.init))
            .map { $0.replacingOccurrences(of: ":", with: "/") }.joined(separator: ":")
        record.appendTag(0, Data(parentName.utf8))
        var parentIDs = Data()
        parentIDs.appendUInt32(parentID)
        record.appendTag(1, parentIDs)
        record.appendTag(2, Data(carbonPath.utf8))
        record.appendTag(14, Self.unicodeName(fileName))
        record.appendTag(15, Self.unicodeName(volumeName))
        record.appendTag(18, Data(pathInVolume.utf8))
        record.appendTag(19, Data(volumeMountPoint.utf8))
        record.appendUInt16(0xFFFF)
        record.appendUInt16(0)

        var size = Data()
        size.appendUInt16(UInt16(record.count))
        record.replace(at: 4, with: size)
        return record
    }

    /// Seconds since 1904, the classic Mac OS epoch.
    static func hfsSeconds(_ date: Date) -> UInt32 {
        UInt32(clamping: Int64(date.timeIntervalSince1970) + 2_082_844_800)
    }

    /// A count of UTF-16 units, then the units.
    static func unicodeName(_ name: String) -> Data {
        var data = Data()
        let units = Array(name.utf16)
        data.appendUInt16(UInt16(units.count))
        for unit in units { data.appendUInt16(unit) }
        return data
    }
}

extension Data {
    /// A length byte, then up to `capacity` bytes of Mac Roman text, padded with zeros.
    mutating func appendPascalString(_ text: String, capacity: Int) {
        let bytes = Array((text.data(using: .macOSRoman, allowLossyConversion: true) ?? Data()).prefix(capacity))
        append(UInt8(bytes.count))
        append(contentsOf: bytes)
        append(Data(count: capacity - bytes.count))
    }

    mutating func appendTag(_ tag: UInt16, _ value: Data) {
        appendUInt16(tag)
        appendUInt16(UInt16(value.count))
        append(value)
        if value.count % 2 == 1 { append(0) }
    }
}
