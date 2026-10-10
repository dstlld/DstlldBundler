//
//  main.swift
//  dstlld-bundler
//
//  Prints warnings as diagnostics, then the `.app`'s path (or, for `export`, the `.dmg`'s) as the
//  last line of standard output, which is how callers find it. An export's steps are printed as
//  `note:` lines as they start, because notarizing can take minutes.
//

import DstlldBundlerCore
import Foundation

func printToStandardError(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "export" {
        let spec = try ToolArguments.parseExport(Array(arguments.dropFirst()))
        let result = try ExportPipeline.run(spec) { step in
            print("note: \(step)")
            fflush(stdout)
        }
        for warning in result.warnings {
            printToStandardError(warning)
        }
        print(result.diskImage.path)
    } else {
        let spec = try ToolArguments.parse(arguments)
        let result = try BundleAssembler.assemble(spec)
        for warning in result.warnings {
            printToStandardError(warning)
        }
        print(result.app.path)
    }
} catch {
    printToStandardError("\(error)")
    exit(1)
}
