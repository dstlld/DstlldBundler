//
//  main.swift
//  dstlld-bundler
//
//  Prints warnings as diagnostics, then the `.app`'s path as the last line of standard output, which
//  is how callers find it.
//

import DstlldBundlerCore
import Foundation

do {
    let spec = try ToolArguments.parse(Array(CommandLine.arguments.dropFirst()))
    let result = try BundleAssembler.assemble(spec)
    for warning in result.warnings {
        FileHandle.standardError.write(Data((warning + "\n").utf8))
    }
    print(result.app.path)
} catch {
    FileHandle.standardError.write(Data(("\(error)\n").utf8))
    exit(1)
}
