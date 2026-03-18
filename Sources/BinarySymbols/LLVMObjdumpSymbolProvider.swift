//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation

package struct LLVMObjdumpSymbolProvider: SymbolProvider {
    private let objdumpPath: AbsolutePath

    // NSRegularExpression equivalent of the original RegexBuilder pattern, avoiding
    // a dependency on _StringProcessing which may not be linkable in bootstrap CMake
    // builds on Windows. Groups: 1=visibility, 2=weak, 3=section, 4=name.
    private static let symbolLineRegex = try! NSRegularExpression(
        pattern: #"^[0-9a-fA-F]{16}[ \t]([lgu! ])([ w])[C ][W ][Ii ][Dd ][FfO ][ \t]+(\S*).*[ \t](\S+)$"#
    )

    package init(objdumpPath: AbsolutePath) {
        self.objdumpPath = objdumpPath
    }

    package func symbols(for binary: AbsolutePath, symbols: inout ReferencedSymbols, recordUndefined: Bool = true) async throws {
        let objdumpProcess = AsyncProcess(args: objdumpPath.pathString, "-t", "-T", binary.pathString)
        try objdumpProcess.launch()
        let result = try await objdumpProcess.waitUntilExit()
        guard case .terminated(let status) = result.exitStatus,
            status == 0 else {
            throw InternalError("Unable to run llvm-objdump")
        }

        try parse(output: try result.utf8Output(), symbols: &symbols, recordUndefined: recordUndefined)
    }

    package func parse(output: String, symbols: inout ReferencedSymbols, recordUndefined: Bool = true) throws {
        for line in output.split(whereSeparator: \.isNewline) {
            let lineString = String(line)
            let range = NSRange(lineString.startIndex..., in: lineString)
            guard let match = Self.symbolLineRegex.firstMatch(in: lineString, range: range),
                  match.numberOfRanges >= 5,
                  let weakRange = Range(match.range(at: 2), in: lineString),
                  let sectionRange = Range(match.range(at: 3), in: lineString),
                  let nameRange = Range(match.range(at: 4), in: lineString) else {
                // This isn't a symbol definition line
                continue
            }

            let weakLinkage = lineString[weakRange]
            let section = String(lineString[sectionRange])
            let name = String(lineString[nameRange])

            switch section {
            case "*UND*":
                guard recordUndefined else {
                    continue
                }
                // Weak symbols are optional
                if weakLinkage != "w" {
                    symbols.addUndefined(name)
                }
            default:
                symbols.addDefined(name)
            }
        }
    }

    private func name(line: Substring) -> Substring? {
        guard let lastspace = line.lastIndex(where: \.isWhitespace) else { return nil }
        return line[line.index(after: lastspace)...]
    }

    private func section(line: Substring) throws -> Substring {
        guard line.count > 25 else {
            throw InternalError("Unable to run llvm-objdump")
        }
        let sectionStart = line.index(line.startIndex, offsetBy: 25)
        guard let sectionEnd = line[sectionStart...].firstIndex(where: \.isWhitespace) else {
            throw InternalError("Unable to run llvm-objdump")
        }
        return line[sectionStart..<sectionEnd]
    }
}

