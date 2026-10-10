//
//  DiskImageBuilder.swift
//  DstlldBundlerCore
//
//  Makes the `.dmg` people download: the app, a link to /Applications, and a window laid out to
//  show dragging one onto the other.
//
//  The window's layout points at the background picture through an alias, and an alias names the
//  volume's creation date and the file's catalogue ids, which exist only once the volume does. So
//  the image is made blank and writable, mounted, filled, laid out, and only then compressed:
//
//    1. `diskutil image create blank` — a sparse bundle with an APFS volume
//    2. `diskutil image attach` — at a private mount point, so a mounted volume of the same name
//       elsewhere cannot get in the way
//    3. copy in the app, `Applications`, `.background/background.tiff`, `.VolumeIcon.icns`, and
//       write `.DS_Store`
//    4. `diskutil eject`, then `diskutil image create from` — compressed with LZFSE (ULFO)
//
//  macOS 27 deprecates `hdiutil` for these jobs in favour of `diskutil image`.
//

import Foundation

public struct DiskImageSpec: Sendable {
    /// The signed `.app` to put on the image.
    public var app: URL
    /// The volume's name, which Finder shows as the window's title.
    public var volumeName: String
    /// The finished `.dmg`. Replaced if it exists.
    public var output: URL
    /// The background picture: a TIFF with 1× and 2× pictures, or any image file.
    public var background: URL
    /// The app's icon, which also becomes the volume's.
    public var volumeIcon: URL?
    /// A folder for the intermediate image and mount point. Emptied first.
    public var workDirectory: URL

    public init(app: URL, volumeName: String, output: URL, background: URL, volumeIcon: URL?, workDirectory: URL) {
        self.app = app
        self.volumeName = volumeName
        self.output = output
        self.background = background
        self.volumeIcon = volumeIcon
        self.workDirectory = workDirectory
    }
}

public enum DiskImageBuilder {
    static let diskutil = URL(filePath: "/usr/sbin/diskutil")
    static let ditto = URL(filePath: "/usr/bin/ditto")
    static let backgroundFolder = ".background"

    public static func build(_ spec: DiskImageSpec) throws(BundlerError) {
        let files = FileManager.default
        let writable = spec.workDirectory.appending(path: "layout.sparsebundle", directoryHint: .isDirectory)
        let mountPoint = spec.workDirectory.appending(path: "volume", directoryHint: .isDirectory)
        try attempt("could not prepare the disk image's work folder") {
            if files.fileExists(atPath: spec.workDirectory.path) { try files.removeItem(at: spec.workDirectory) }
            try files.createDirectory(at: spec.workDirectory, withIntermediateDirectories: true)
            if files.fileExists(atPath: spec.output.path) { try files.removeItem(at: spec.output) }
        }

        let size = blankSize(appBytes: allocatedSize(of: spec.app))
        try Command.run(diskutil, [
            "image", "create", "blank", "--format", "UDSB", "--fs", "APFS", "--size", String(size),
            "--volumeName", spec.volumeName, writable.path,
        ]).check(doing: "creating the disk image")
        try Command.run(diskutil, [
            "image", "attach", "--nobrowse", "--mountPoint", mountPoint.path, writable.path,
        ]).check(doing: "mounting the disk image")

        do {
            try fill(mountPoint, with: spec)
        } catch {
            // Eject on the way out so a failed export leaves nothing mounted; the fill's error is the
            // one to report.
            _ = Command.run(diskutil, ["eject", mountPoint.path])
            throw error
        }
        try Command.run(diskutil, ["eject", mountPoint.path]).check(doing: "ejecting the disk image")

        try Command.run(diskutil, [
            "image", "create", "from", "--format", "ULFO", writable.path, spec.output.path,
        ]).check(doing: "compressing the disk image")
        // The intermediate image is large and no longer needed; a leftover is only wasted space.
        try? files.removeItem(at: writable)
    }

    /// Room for the app, its copy's metadata, and the layout files, with a floor for small apps.
    static func blankSize(appBytes: Int) -> Int {
        max(appBytes + appBytes / 5 + 16 << 20, 64 << 20)
    }

    private static func fill(_ volume: URL, with spec: DiskImageSpec) throws(BundlerError) {
        let files = FileManager.default
        let appName = spec.app.lastPathComponent
        try Command.run(ditto, [spec.app.path, volume.appending(path: appName).path])
            .check(doing: "copying \(appName) onto the disk image")

        let backgroundFolder = volume.appending(path: Self.backgroundFolder, directoryHint: .isDirectory)
        let background = backgroundFolder.appending(path: "background.\(spec.background.pathExtension)")
        try attempt("could not lay out the disk image") {
            try files.createSymbolicLink(
                at: volume.appending(path: "Applications"), withDestinationURL: URL(filePath: "/Applications"))
            try files.createDirectory(at: backgroundFolder, withIntermediateDirectories: true)
            try files.copyItem(at: spec.background, to: background)
        }
        if let volumeIcon = spec.volumeIcon {
            try attempt("could not give the disk image an icon") {
                try files.copyItem(at: volumeIcon, to: volume.appending(path: ".VolumeIcon.icns"))
            }
            try setHasCustomIcon(volume)
        }

        let alias = try AliasRecord.for(
            file: background, onVolumeAt: volume, publicMountPoint: "/Volumes/\(spec.volumeName)")
        let records = try DSStore.diskImageWindow(
            size: BackgroundRenderer.size, iconSize: BackgroundRenderer.iconSize,
            textSize: BackgroundRenderer.textSize, background: alias.data,
            positions: [
                (appName, BackgroundRenderer.appPosition.x, BackgroundRenderer.appPosition.y),
                ("Applications", BackgroundRenderer.applicationsPosition.x, BackgroundRenderer.applicationsPosition.y),
            ])
        let store = try DSStore.data(records)
        try attempt("could not write the disk image's window layout") {
            try store.write(to: volume.appending(path: ".DS_Store"))
        }
    }

    /// Sets Finder's "has a custom icon" flag on the volume's root, so it shows `.VolumeIcon.icns`.
    static func setHasCustomIcon(_ folder: URL) throws(BundlerError) {
        // Finder information is 32 bytes; the flags are the big-endian 16 bits at offset 8.
        var info = [UInt8](repeating: 0, count: 32)
        info[8] = 0x04  // kHasCustomIcon, 0x0400
        let status = info.withUnsafeBytes { bytes in
            setxattr(folder.path, "com.apple.FinderInfo", bytes.baseAddress, bytes.count, 0, 0)
        }
        guard status == 0 else {
            throw BundlerError("could not give the disk image an icon: \(String(cString: strerror(errno)))")
        }
    }

    static func allocatedSize(of folder: URL) -> Int {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total = 0
        for case let item as URL in items {
            // A file whose size can't be read counts as empty; blankSize leaves headroom anyway.
            total += (try? item.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0
        }
        return total
    }

    private static func attempt(_ what: String, _ body: () throws -> Void) throws(BundlerError) {
        do {
            try body()
        } catch {
            throw BundlerError("\(what): \(error.localizedDescription)")
        }
    }
}
