//
//  SwiftFormat.swift
//  SwiftFormat
//
//  Created by Nick Lockwood on 12/08/2016.
//  Copyright 2016 Nick Lockwood
//
//  Distributed under the permissive MIT license
//  Get the latest version from here:
//
//  https://github.com/nicklockwood/SwiftFormat
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation

/// The current SwiftFormat version
let swiftFormatVersion = "0.49.15"
public let version = swiftFormatVersion

/// The standard SwiftFormat config file name
public let swiftFormatConfigurationFile = ".swiftformat"

/// The standard Swift version file name
public let swiftVersionFile = ".swift-version"

/// Supported Swift versions
public let swiftVersions = [
    "3.x", "4.0", "4.1", "4.2",
    "5.0", "5.1", "5.2", "5.3", "5.4", "5.5", "5.6", "5.7",
]

/// An enumeration of the types of error that may be thrown by SwiftFormat
public enum FormatError: Error, CustomStringConvertible, LocalizedError, CustomNSError {
    case reading(String)
    case writing(String)
    case parsing(String)
    case options(String)

    public var description: String {
        switch self {
        case let .reading(string),
             let .writing(string),
             let .parsing(string),
             let .options(string):
            return string
        }
    }

    public var localizedDescription: String {
        return "Error: \(description)."
    }

    public var errorUserInfo: [String: Any] {
        return [NSLocalizedDescriptionKey: localizedDescription]
    }
}

/// Callback for enumerateFiles() function
public typealias FileEnumerationHandler = (
    _ inputURL: URL,
    _ ouputURL: URL,
    _ options: Options
) throws -> () throws -> Void

/// Callback for info-level logging
public typealias Logger = (String) -> Void

/// Enumerate all Swift files at the specified location and (optionally) calculate an output file URL for each.
/// Ignores the file if any of the excluded file URLs is a prefix of the input file URL.
///
/// Files are enumerated concurrently. For convenience, the enumeration block returns a completion block, which
/// will be executed synchronously on the calling thread once enumeration is complete.
///
/// Errors may be thrown by either the enumeration block or the completion block, and are gathered into an
/// array and returned after enumeration is complete, along with any errors generated by the function itself.
/// Throwing an error from inside either block does *not* terminate the enumeration.
public func enumerateFiles(withInputURL inputURL: URL,
                           outputURL: URL? = nil,
                           options baseOptions: Options = .default,
                           concurrent: Bool = true,
                           logger: Logger? = nil,
                           skipped: FileEnumerationHandler? = nil,
                           handler: @escaping FileEnumerationHandler) -> [Error]
{
    let manager = FileManager.default
    let keys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey,
        .isAliasFileKey, .isSymbolicLinkKey,
        .creationDateKey, .pathKey,
    ]

    let group = DispatchGroup()
    var completionBlocks = [() throws -> Void]()
    let completionQueue = DispatchQueue(label: "swiftformat.enumeration")
    func onComplete(_ block: @escaping () throws -> Void) {
        completionQueue.async(group: group) {
            completionBlocks.append(block)
        }
    }

    let queue = concurrent ? DispatchQueue.global(qos: .userInitiated) : completionQueue

    func resolveInputURL(_ inputURL: URL, options: Options) -> (URL, ResourceValues, Options)? {
        let fileOptions = options.fileOptions ?? .default
        let inputURL = inputURL.standardizedFileURL
        if options.shouldSkipFile(inputURL) {
            if let handler = skipped {
                do {
                    onComplete(try handler(inputURL, inputURL, options))
                } catch {
                    onComplete { throw error }
                }
            }
            return nil
        }
        do {
            let resourceValues = try getResourceValues(for: inputURL, keys: keys)
            #if os(macOS)
                if resourceValues.isAliasFile == true {
                    if fileOptions.followSymlinks {
                        guard let resolvedURL = try? URL(resolvingAliasFileAt: inputURL) else {
                            throw FormatError.options("Could not resolve alias at \(inputURL.path)")
                        }
                        return resolveInputURL(resolvedURL, options: options)
                    } else {
                        if let handler = skipped {
                            onComplete(try handler(inputURL, inputURL, options))
                        }
                        return nil
                    }
                }
            #endif
            if resourceValues.isSymbolicLink == true {
                if fileOptions.followSymlinks {
                    let resolvedURL = inputURL.resolvingSymlinksInPath()
                    return resolveInputURL(resolvedURL, options: options)
                } else {
                    if let handler = skipped {
                        onComplete(try handler(inputURL, inputURL, options))
                    }
                    return nil
                }
            } else {
                return (inputURL, resourceValues, options)
            }
        } catch {
            onComplete { throw error }
            return nil
        }
    }

    func enumerate(inputURL: URL,
                   outputURL: URL?,
                   options: Options)
    {
        assert(options.formatOptions != nil)
        guard let (inputURL, resourceValues, options) = resolveInputURL(inputURL, options: options) else {
            return
        }
        assert(options.formatOptions != nil)
        let fileOptions = options.fileOptions ?? .default
        if resourceValues.isRegularFile == true {
            if fileOptions.supportedFileExtensions.contains(inputURL.pathExtension) {
                let fileInfo = FileInfo(
                    filePath: resourceValues.path,
                    creationDate: resourceValues.creationDate
                )
                var options = options
                options.formatOptions?.fileInfo = fileInfo
                do {
                    onComplete(try handler(inputURL, outputURL ?? inputURL, options))
                } catch {
                    onComplete { throw error }
                }
            }
        } else if resourceValues.isDirectory == true {
            var options = options
            do {
                try processDirectory(inputURL, with: &options, logger: logger)
            } catch {
                onComplete { throw error }
                return
            }
            let enumerationOptions: FileManager.DirectoryEnumerationOptions = .skipsHiddenFiles
            guard let files = try? manager.contentsOfDirectory(
                at: inputURL, includingPropertiesForKeys: keys, options: enumerationOptions
            ) else {
                onComplete { throw FormatError.reading("Failed to read contents of directory at \(inputURL.path)") }
                return
            }
            for url in files where !url.path.hasPrefix(".") {
                queue.async(group: group) {
                    let outputURL = outputURL.map {
                        URL(fileURLWithPath: $0.path + url.path[inputURL.path.endIndex ..< url.path.endIndex])
                    }
                    enumerate(inputURL: url, outputURL: outputURL, options: options)
                }
            }
        }
    }

    queue.async(group: group) {
        var options = baseOptions
        var inputURL = inputURL
        if options.formatOptions == nil {
            options.formatOptions = .default
        }
        do {
            try gatherOptions(&options, for: inputURL, with: logger)
            guard let (resolvedURL, resourceValues, _) = resolveInputURL(inputURL, options: options) else {
                return
            }
            inputURL = resolvedURL
            let fileOptions = options.fileOptions ?? .default
            if resourceValues.isDirectory == false,
               !fileOptions.supportedFileExtensions.contains(inputURL.pathExtension)
            {
                throw FormatError.options("Unsupported file type: \(inputURL.path)")
            }
        } catch {
            onComplete { throw error }
            return
        }
        enumerate(inputURL: inputURL, outputURL: outputURL, options: options)
    }
    group.wait()

    var errors = [Error]()
    for block in completionBlocks {
        do {
            try block()
        } catch {
            errors.append(error)
        }
    }
    return errors
}

// Process configuration in all directories in specified path.
func gatherOptions(_ options: inout Options, for inputURL: URL, with logger: Logger?) throws {
    var directory = URL(fileURLWithPath: inputURL.pathComponents[0]).standardized
    for part in inputURL.pathComponents.dropFirst().dropLast() {
        directory.appendPathComponent(part)
        if options.shouldSkipFile(directory) {
            return
        }
        try processDirectory(directory, with: &options, logger: logger)
    }
}

// Process configuration files in specified directory.
private var configCache = [URL: [String: String]]()
private let configQueue = DispatchQueue(label: "swiftformat.config", qos: .userInteractive)
private func processDirectory(_ inputURL: URL, with options: inout Options, logger: Logger?) throws {
    if let args = configQueue.sync(execute: { configCache[inputURL] }) {
        try options.addArguments(args, in: inputURL.path)
        return
    }
    var args = [String: String]()
    let manager = FileManager.default
    let configFile = inputURL.appendingPathComponent(swiftFormatConfigurationFile)
    if manager.fileExists(atPath: configFile.path) {
        logger?("Reading config file at \(configFile.path)")
        let data = try Data(contentsOf: configFile)
        args = try parseConfigFile(data)
    }
    let versionFile = inputURL.appendingPathComponent(swiftVersionFile)
    if manager.fileExists(atPath: versionFile.path) {
        let versionString = try String(contentsOf: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if Version(rawValue: versionString) != nil {
            args["swiftversion"] = versionString
        } else {
            // Don't treat as error, per: https://github.com/nicklockwood/SwiftFormat/issues/639
            // TODO: find a better solution for logging warnings here
            logger?("Unrecognized swift version string '\(versionString)' in \(versionFile.path)")
        }
    }
    configQueue.async {
        configCache[inputURL] = args
    }
    assert(options.formatOptions != nil)
    try options.addArguments(args, in: inputURL.path)
}

/// Line and column offset in source
/// Note: line and column indexes start at 1
public struct SourceOffset: Equatable, CustomStringConvertible {
    var line, column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public var description: String {
        return "\(line):\(column)"
    }
}

/// Get offset for token
public func offsetForToken(at index: Int, in tokens: [Token], tabWidth: Int) -> SourceOffset {
    var column = 1
    for token in tokens[..<index].reversed() {
        switch token {
        case let .linebreak(_, line):
            return SourceOffset(line: line + 1, column: column)
        default:
            column += token.columnWidth(tabWidth: tabWidth)
        }
    }
    return SourceOffset(line: 1, column: column)
}

/// Get token index for offset
public func tokenIndex(for offset: SourceOffset, in tokens: [Token], tabWidth: Int) -> Int {
    var tokenIndex = 0, line = 1
    for index in tokens.indices {
        guard case let .linebreak(_, originalLine) = tokens[index] else {
            continue
        }
        line = originalLine
        guard originalLine < offset.line else {
            break
        }
        tokenIndex = index + 1
    }
    if line < offset.line - 1 {
        return tokens.endIndex
    }
    var column = 1
    while tokenIndex < tokens.endIndex, column < offset.column {
        column += tokens[tokenIndex].columnWidth(tabWidth: tabWidth)
        tokenIndex += 1
    }
    return tokenIndex
}

/// Deprecated
@available(*, deprecated, message: "Use tokenIndex(for:) instead")
public func tokenIndexForOffset(_ offset: SourceOffset, in tokens: [Token], tabWidth: Int) -> Int {
    return tokenIndex(for: offset, in: tokens, tabWidth: tabWidth)
}

/// Get token index range for line range
public func tokenRange(forLineRange lineRange: ClosedRange<Int>, in tokens: [Token]) -> Range<Int> {
    let startOffset = SourceOffset(line: lineRange.lowerBound, column: 0)
    let endOffset = SourceOffset(line: lineRange.upperBound + 1, column: 0)
    // NOTE: tab width is not relevant for line-based offsets
    return tokenIndex(for: startOffset, in: tokens, tabWidth: 1)
        ..< tokenIndex(for: endOffset, in: tokens, tabWidth: 1)
}

/// Get new offset for an original offset (before formatting)
public func newOffset(for offset: SourceOffset, in tokens: [Token], tabWidth: Int) -> SourceOffset {
    var closestLine = 0
    for i in tokens.indices {
        guard case let .linebreak(_, originalLine) = tokens[i] else {
            continue
        }
        closestLine += 1
        guard originalLine >= offset.line else {
            continue
        }
        var lineLength = 0
        for j in (0 ..< i).reversed() {
            let token = tokens[j]
            if token.isLinebreak {
                break
            }
            lineLength += token.columnWidth(tabWidth: tabWidth)
        }
        return SourceOffset(line: closestLine, column: min(offset.column, lineLength + 1))
    }
    let lineLength = tokens.reduce(0) { $0 + $1.columnWidth(tabWidth: tabWidth) }
    return SourceOffset(line: closestLine + 1, column: min(offset.column, lineLength + 1))
}

/// Process parsing errors
public func parsingError(for tokens: [Token], options: FormatOptions) -> FormatError? {
    guard let index = tokens.index(where: {
        guard options.fragment || !$0.isError else { return true }
        guard !options.ignoreConflictMarkers, case let .operator(string, _) = $0 else { return false }
        return string.hasPrefix("<<<<<") || string.hasPrefix("=====") || string.hasPrefix(">>>>>")
    }) else {
        return nil
    }
    let message: String
    switch tokens[index] {
    case .error(""):
        message = "Unexpected end of file"
    case let .error(string):
        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = "Inconsistent whitespace in multi-line string literal"
        } else {
            message = "Unexpected token \(string)"
        }
    case let .operator(string, _):
        message = "Found conflict marker \(string)"
    default:
        preconditionFailure()
    }
    let offset = offsetForToken(at: index, in: tokens, tabWidth: options.tabWidth)
    return .parsing("\(message) at \(offset)")
}

/// Convert a token array back into a string
public func sourceCode(for tokens: [Token]?) -> String {
    return (tokens ?? []).map { $0.string }.joined()
}

/// Apply specified rules to a token array and optionally capture list of changes
public func applyRules(_ rules: [FormatRule],
                       to originalTokens: [Token],
                       with options: FormatOptions,
                       trackChanges: Bool,
                       range: Range<Int>?) throws -> (tokens: [Token], changes: [Formatter.Change])
{
    return try applyRules(rules,
                          to: originalTokens,
                          with: options,
                          trackChanges: trackChanges,
                          range: range,
                          callback: nil)
}

private func applyRules(
    _ rules: [FormatRule],
    to originalTokens: [Token],
    with options: FormatOptions,
    trackChanges: Bool,
    range: Range<Int>?,
    maxIterations: Int = 10,
    callback: ((Int, [Token]) -> Void)? = nil
) throws -> (tokens: [Token], changes: [Formatter.Change]) {
    precondition(maxIterations > 1)
    var rules = rules
    var tokens = originalTokens

    // Ensure rule names have been set
    if rules.first?.name == "" {
        _ = FormatRules.all
    }

    // Check for parsing errors
    if let error = parsingError(for: tokens, options: options) {
        throw error
    }

    // Infer shared options
    var options = options
    options.enabledRules = Set(rules.map { $0.name })
    let sharedOptions = FormatRules
        .sharedOptionsForRules(rules)
        .compactMap { Descriptors.byName[$0] }
        .filter { $0.defaultArgument == $0.fromOptions(options) }
        .map { $0.propertyName }

    inferFormatOptions(sharedOptions, from: tokens, into: &options)

    // Check if required FileInfo is available
    if rules.contains(FormatRules.fileHeader) {
        if options.fileHeader.rawValue.contains("{created"),
           options.fileInfo.creationDate == nil
        {
            throw FormatError.options(
                "Failed to apply {created} template in file header as file info is unavailable"
            )
        }
        if options.fileHeader.rawValue.contains("{file"),
           options.fileInfo.fileName == nil
        {
            throw FormatError.options(
                "Failed to apply {file} template in file header as file name was not provided"
            )
        }
    }

    // Split tokens into lines
    func lines(in tokens: [Token]) -> [Int: ArraySlice<Token>?] {
        var lines: [Int: ArraySlice<Token>?] = [:]
        var start = 0
        for (i, token) in tokens.enumerated() {
            if case let .linebreak(_, line) = token {
                lines[line] = tokens[start ..< i]
                start = i + 1
            }
        }
        return lines
    }

    // Recursively apply rules until no changes are detected
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "swiftformat.formatting", qos: .userInteractive)
    let timeout = 1 + TimeInterval(tokens.count) / 100
    var changes = [Formatter.Change]()
    for _ in 0 ..< maxIterations {
        let formatter = Formatter(tokens, options: options,
                                  trackChanges: trackChanges, range: range)
        for (i, rule) in rules.sorted().enumerated() {
            queue.async(group: group) {
                rule.apply(with: formatter)
            }
            guard group.wait(timeout: .now() + timeout) != .timedOut else {
                throw FormatError.writing("\(rule.name) rule timed out")
            }
            callback?(i, formatter.tokens)
        }
        if let error = formatter.errors.first, !options.fragment {
            throw error
        }
        changes += formatter.changes
        if tokens == formatter.tokens {
            if changes.isEmpty {
                return (tokens, [])
            }
            // Sort changes
            changes.sort(by: {
                if $0.line == $1.line {
                    return $0.rule.name < $1.rule.name
                }
                return $0.line < $1.line
            })
            // Get lines
            let oldLines = lines(in: originalTokens)
            let newLines = lines(in: tokens)
            // Filter out duplicates and lines that haven't changed
            var last: Formatter.Change?
            return (tokens, changes.filter { change in
                if last == change {
                    return false
                }
                last = change
                if newLines[change.line] == oldLines[change.line] {
                    return false
                }
                return true
            })
        }
        tokens = formatter.tokens
        rules.removeAll(where: { $0.runOnceOnly }) // Prevents infinite recursion
    }
    throw FormatError.writing("Failed to terminate")
}

/// Format a pre-parsed token array
/// Returns the formatted token array
public func format(
    _ tokens: [Token], rules: [FormatRule] = FormatRules.default,
    options: FormatOptions = .default, range: Range<Int>? = nil
) throws -> [Token] {
    return try applyRules(rules, to: tokens, with: options, trackChanges: false, range: range).tokens
}

/// Format code with specified rules and options
public func format(
    _ source: String, rules: [FormatRule] = FormatRules.default,
    options: FormatOptions = .default, lineRange: ClosedRange<Int>? = nil
) throws -> String {
    let tokens = tokenize(source)
    let range = lineRange.map { tokenRange(forLineRange: $0, in: tokens) }
    return sourceCode(for: try format(tokens, rules: rules, options: options, range: range))
}

/// Lint a pre-parsed token array
/// Returns the list of edits made
public func lint(
    _ tokens: [Token], rules: [FormatRule] = FormatRules.default,
    options: FormatOptions = .default, range: Range<Int>? = nil
) throws -> [Formatter.Change] {
    return try applyRules(rules, to: tokens, with: options, trackChanges: true, range: range).changes
}

/// Lint code with specified rules and options
public func lint(
    _ source: String, rules: [FormatRule] = FormatRules.default,
    options: FormatOptions = .default, lineRange: ClosedRange<Int>? = nil
) throws -> [Formatter.Change] {
    let tokens = tokenize(source)
    let range = lineRange.map { tokenRange(forLineRange: $0, in: tokens) }
    return try lint(tokens, rules: rules, options: options, range: range)
}

// MARK: Path utilities

public func expandPath(_ path: String, in directory: String) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path).standardized
    }
    if path.hasPrefix("~") {
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardized
    }
    return URL(fileURLWithPath: directory).appendingPathComponent(path).standardized
}

struct ResourceValues {
    let isRegularFile: Bool?
    let isDirectory: Bool?
    let isAliasFile: Bool?
    let isSymbolicLink: Bool?
    let creationDate: Date?
    let path: String?
}

func getResourceValues(for url: URL, keys: [URLResourceKey]) throws -> ResourceValues {
    let manager = FileManager.default
    #if os(macOS)
        if let resourceValues = try? url.resourceValues(forKeys: Set(keys)) {
            return ResourceValues(
                isRegularFile: resourceValues.isRegularFile,
                isDirectory: resourceValues.isDirectory,
                isAliasFile: resourceValues.isAliasFile,
                isSymbolicLink: resourceValues.isSymbolicLink,
                creationDate: resourceValues.creationDate,
                path: resourceValues.path
            )
        }
        if manager.fileExists(atPath: url.path) {
            throw FormatError.reading("Failed to read attributes for \(url.path)")
        }
    #else
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard let attributes = try? manager.attributesOfItem(atPath: url.path) else {
                throw FormatError.reading("Failed to read attributes for \(url.path)")
            }
            let isSymbolicLink = url.resolvingSymlinksInPath() != url
            return ResourceValues(
                isRegularFile: !isDirectory.boolValue && !isSymbolicLink,
                isDirectory: isDirectory.boolValue,
                isAliasFile: false,
                isSymbolicLink: isSymbolicLink,
                creationDate: attributes[.creationDate] as? Date,
                path: url.path
            )
        }
    #endif
    throw FormatError.options("File not found at \(url.path)")
}

// MARK: Documentation utilities

// Strip markdown code-formatting
func stripMarkdown(_ input: String) -> String {
    var result = ""
    var startCount = 0
    var endCount = 0
    var escaped = false
    for c in input {
        if c == "`" {
            if escaped {
                endCount += 1
            } else {
                startCount += 1
            }
        } else {
            if escaped, endCount > 0 {
                if endCount != startCount {
                    result += String(repeating: "`", count: endCount)
                } else {
                    escaped = false
                    startCount = 0
                }
                endCount = 0
            }
            if startCount > 0 {
                escaped = true
            }
            result.append(c)
        }
    }
    return result
}
