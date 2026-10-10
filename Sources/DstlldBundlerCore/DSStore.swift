//
//  DSStore.swift
//  DstlldBundlerCore
//
//  Writes a `.DS_Store`, the file where Finder keeps a folder's window: its size, view, background
//  and where each icon sits. Writing it directly, instead of laying the window out by scripting
//  Finder, needs no Automation permission, opens no windows, and gives the same bytes every time.
//
//  The format is undocumented. What is written here follows the community's description of it
//  (Mark Mentovai's and Alastair Houghton's notes, and dmgbuild's `ds_store` package):
//
//  - The file is a buddy allocator. A 4-byte `00 00 00 01` comes first, then everything else is
//    addressed from byte 4. Blocks are powers of two, aligned to their size, from 32 bytes to 2 GB.
//    A block's address is its offset with log2(size) in the low five bits.
//  - The allocator's own block lists every block address, a table of contents (`DSDB` → the
//    B-tree's header block) and, for each size, the free blocks.
//  - The B-tree holds records sorted by file name (case-insensitively), then by four-character code.
//    A folder's window has few records, so one leaf node is enough, and this writer only makes one.
//
//  Layout of what this writes, as offsets from byte 4:
//
//      0     32 B   file header ("Bud1", root block offset and size)
//      32    32 B   B-tree header (DSDB)
//      2048  2 KB   allocator block
//      4096  4 KB   the B-tree's only node, a leaf
//
//  Every other aligned block is free, from 64 bytes up to 1 GB.
//

import Foundation

public enum DSStore {
    /// One property of one item in the folder. `name` is `.` for the folder itself.
    public struct Record: Sendable, Equatable {
        public var name: String
        /// A four-character code, such as `Iloc` or `icvp`.
        public var code: String
        public var value: Value

        public init(name: String, code: String, value: Value) {
            precondition(code.utf8.count == 4, "a record code is four ASCII characters")
            self.name = name
            self.code = code
            self.value = value
        }
    }

    public enum Value: Sendable, Equatable {
        case long(UInt32)
        case bool(Bool)
        /// Opaque bytes, often a binary property list.
        case blob(Data)
        /// A four-character code.
        case type(String)
        case string(String)

        var typeCode: String {
            switch self {
            case .long: "long"
            case .bool: "bool"
            case .blob: "blob"
            case .type: "type"
            case .string: "ustr"
            }
        }
    }

    static let pageSize = 4096
    static let headerBlock = (offset: 32, log2Size: 5)
    static let allocatorBlock = (offset: 2048, log2Size: 11)
    static let leafBlock = (offset: 4096, log2Size: 12)

    /// The file's bytes.
    public static func data(_ records: [Record]) throws(BundlerError) -> Data {
        let leaf = leafNode(sorted(records))
        guard leaf.count <= pageSize else {
            throw BundlerError("the disk image's window layout is too large for one .DS_Store page")
        }

        // Offsets in this file count from byte 4, after the leading 00 00 00 01.
        var body = Data(count: leafBlock.offset + pageSize)

        var header = Data()
        header.append(contentsOf: Array("Bud1".utf8))
        header.appendUInt32(UInt32(allocatorBlock.offset))
        header.appendUInt32(UInt32(1 << allocatorBlock.log2Size))
        header.appendUInt32(UInt32(allocatorBlock.offset))
        header.append(Data(count: 16))
        body.replace(at: 0, with: header)

        var tree = Data()
        tree.appendUInt32(2)  // the root node is block 2, the leaf
        tree.appendUInt32(0)  // levels above the leaves
        tree.appendUInt32(UInt32(records.count))
        tree.appendUInt32(1)  // nodes
        tree.appendUInt32(UInt32(pageSize))
        body.replace(at: headerBlock.offset, with: tree)

        body.replace(at: allocatorBlock.offset, with: allocator())
        body.replace(at: leafBlock.offset, with: leaf)

        var file = Data([0, 0, 0, 1])
        file.append(body)
        return file
    }

    /// Records in the order Finder searches them.
    static func sorted(_ records: [Record]) -> [Record] {
        records.sorted { left, right in
            let order = left.name.compare(right.name, options: [.caseInsensitive, .literal])
            if order != .orderedSame { return order == .orderedAscending }
            return left.code < right.code
        }
    }

    static func leafNode(_ records: [Record]) -> Data {
        var node = Data()
        node.appendUInt32(0)  // a leaf has no child pointer
        node.appendUInt32(UInt32(records.count))
        for record in records {
            node.appendUTF16String(record.name)
            node.append(contentsOf: Array(record.code.utf8))
            node.append(contentsOf: Array(record.value.typeCode.utf8))
            switch record.value {
            case .long(let value):
                node.appendUInt32(value)
            case .bool(let value):
                node.append(value ? 1 : 0)
            case .blob(let data):
                node.appendUInt32(UInt32(data.count))
                node.append(data)
            case .type(let code):
                precondition(code.utf8.count == 4, "a type value is four ASCII characters")
                node.append(contentsOf: Array(code.utf8))
            case .string(let text):
                node.appendUTF16String(text)
            }
        }
        return node
    }

    static func allocator() -> Data {
        var block = Data()
        let addresses = [allocatorBlock, headerBlock, leafBlock].map { UInt32($0.offset | $0.log2Size) }
        block.appendUInt32(UInt32(addresses.count))
        block.appendUInt32(0)
        // The address table is padded to a multiple of 256 entries.
        for index in 0..<256 {
            block.appendUInt32(index < addresses.count ? addresses[index] : 0)
        }
        // Table of contents: one entry, the B-tree.
        block.appendUInt32(1)
        block.append(4)
        block.append(contentsOf: Array("DSDB".utf8))
        block.appendUInt32(1)
        // Free lists, one per block size. The used blocks are 0–64 (two 32s), 2048–4096 and
        // 4096–8192; the free buddies of everything else are one block of each other size.
        for log2Size in 0..<32 {
            let isFree = (6...30).contains(log2Size) && log2Size != 11 && log2Size != 12
            if isFree {
                block.appendUInt32(1)
                block.appendUInt32(UInt32(1) << UInt32(log2Size))
            } else {
                block.appendUInt32(0)
            }
        }
        return block
    }

    // MARK: - The records a disk image window needs

    /// A disk image's window: no toolbar or sidebar, icon view, a background picture, and each
    /// item at its place.
    ///
    /// - Parameters:
    ///   - size: the window's content size in points, which is also the background's size. The
    ///     window is taller by its title bar, which Finder counts in the window's bounds.
    ///   - background: an alias record for the background picture (see `AliasRecord`).
    ///   - positions: each item's name and the centre of its icon, from the top left.
    public static func diskImageWindow(
        size: (width: Int, height: Int), iconSize: Int, textSize: Int, background: Data,
        positions: [(name: String, x: Int, y: Int)]
    ) throws(BundlerError) -> [Record] {
        let browserWindow: [String: Any] = [
            "ContainerShowSidebar": false,
            "PreviewPaneVisibility": false,
            "ShowPathbar": false,
            "ShowSidebar": false,
            "ShowStatusBar": false,
            "ShowTabView": false,
            "ShowToolbar": false,
            "SidebarWidth": 0,
            "WindowBounds": "{{200, 120}, {\(size.width), \(size.height + titleBarHeight)}}",
        ]
        let iconView: [String: Any] = [
            "arrangeBy": "none",
            "backgroundColorBlue": 1.0,
            "backgroundColorGreen": 1.0,
            "backgroundColorRed": 1.0,
            "backgroundImageAlias": background,
            "backgroundType": 2,  // a picture
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "gridSpacing": 100.0,
            "iconSize": Double(iconSize),
            "labelOnBottom": true,
            "scrollPositionX": 0.0,
            "scrollPositionY": 0.0,
            "showIconPreview": false,
            "showItemInfo": false,
            "textSize": Double(textSize),
            "viewOptionsVersion": 1,
        ]
        var records = [
            Record(name: ".", code: "bwsp", value: .blob(try binaryPlist(browserWindow))),
            Record(name: ".", code: "icvp", value: .blob(try binaryPlist(iconView))),
            Record(name: ".", code: "vSrn", value: .long(1)),
        ]
        for position in positions {
            records.append(Record(name: position.name, code: "Iloc", value: .blob(iconLocation(x: position.x, y: position.y))))
        }
        return records
    }

    /// Finder's title bar on macOS 26 and 27, measured.
    static let titleBarHeight = 32

    /// An `Iloc` value: the icon's centre, then six bytes Finder always writes as `FF` and two as `00`.
    static func iconLocation(x: Int, y: Int) -> Data {
        var data = Data()
        data.appendUInt32(UInt32(x))
        data.appendUInt32(UInt32(y))
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00])
        return data
    }

    static func binaryPlist(_ value: [String: Any]) throws(BundlerError) -> Data {
        do {
            return try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        } catch {
            throw BundlerError("could not encode the disk image's window settings: \(error.localizedDescription)")
        }
    }
}

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt16(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    /// A count of UTF-16 code units, then the units, big-endian.
    mutating func appendUTF16String(_ text: String) {
        let units = Array(text.utf16)
        appendUInt32(UInt32(units.count))
        for unit in units { appendUInt16(unit) }
    }

    mutating func replace(at offset: Int, with bytes: Data) {
        replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
