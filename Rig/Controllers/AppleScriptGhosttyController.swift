import AppKit
import Foundation

enum GhosttyControllerError: LocalizedError {
    case scriptCompilationFailed
    case scriptExecutionFailed(String)
    case invalidScriptResult
    case ghosttyNotInstalled

    var errorDescription: String? {
        switch self {
        case .scriptCompilationFailed:
            "AppleScript could not be compiled."
        case .scriptExecutionFailed(let message):
            message
        case .invalidScriptResult:
            "Ghostty returned an unreadable AppleScript result."
        case .ghosttyNotInstalled:
            "Ghostty is not installed in /Applications."
        }
    }
}

@MainActor
final class AppleScriptGhosttyController: GhosttyControlling {
    private let decoder = JSONDecoder()
    private let ghosttyApplicationPath = "/Applications/Ghostty.app"

    func createWindow(workingDirectory: String) async throws -> CreatedGhosttySurface {
        try Task.checkCancellation()

        guard FileManager.default.fileExists(atPath: ghosttyApplicationPath) else {
            throw GhosttyControllerError.ghosttyNotInstalled
        }

        let json = try run(script: """
        \(Self.jsonHandlers)

        tell application "Ghostty"
            set existingWindowIds to {}
            try
                set winCountBefore to count of windows
                repeat with winIdx from 1 to winCountBefore
                    try
                        copy (id of (window winIdx) as text) to end of existingWindowIds
                    end try
                end repeat
            end try

            set cfg to new surface configuration
            set initial working directory of cfg to \(Self.appleScriptLiteral(workingDirectory))
            set createdWin to new window with configuration cfg

            set targetWin to missing value
            set targetTab to missing value
            set targetTerm to missing value

            repeat 30 times
                try
                    set candidateId to id of createdWin as text
                    if existingWindowIds does not contain candidateId then
                        set targetWin to createdWin
                        set targetTab to selected tab of createdWin
                        set targetTerm to focused terminal of targetTab
                        exit repeat
                    end if
                end try
                delay 0.05
            end repeat

            if targetTerm is missing value then
                try
                    set winCountAfter to count of windows
                    repeat with winIdx from 1 to winCountAfter
                        try
                            set winRef to window winIdx
                            set winId to id of winRef as text
                            if existingWindowIds does not contain winId then
                                set targetWin to winRef
                                set targetTab to selected tab of winRef
                                set targetTerm to focused terminal of targetTab
                                exit repeat
                            end if
                        end try
                    end repeat
                end try
            end if

            if targetTerm is missing value then error "Rig could not verify the newly created Ghostty terminal."

            select tab targetTab
            focus targetTerm

            set output to "{"
            set output to output & "\\"windowId\\":" & my jsonString(id of targetWin)
            set output to output & ",\\"tabId\\":" & my jsonString(id of targetTab)
            set output to output & ",\\"terminalId\\":" & my jsonString(id of targetTerm)
            set output to output & ",\\"workingDirectory\\":" & my jsonString(working directory of targetTerm)
            set output to output & "}"
            return output
        end tell
        """)

        try Task.checkCancellation()
        return try decoder.decode(CreatedGhosttySurface.self, from: Data(json.utf8))
    }

    func focusTerminal(
        windowId: String,
        tabId: String,
        terminalId: String
    ) async throws -> CreatedGhosttySurface {
        try Task.checkCancellation()

        let json = try run(script: """
        \(Self.jsonHandlers)

        tell application "Ghostty"
            set expectedWindowId to \(Self.appleScriptLiteral(windowId))
            set expectedTabId to \(Self.appleScriptLiteral(tabId))
            set expectedTerminalId to \(Self.appleScriptLiteral(terminalId))

            set targetWin to missing value
            set winCount to 0
            try
                set winCount to count of windows
            end try
            repeat with winIdx from 1 to winCount
                try
                    set winRef to window winIdx
                    if (id of winRef as text) is expectedWindowId then
                        set targetWin to winRef
                        exit repeat
                    end if
                end try
            end repeat
            if targetWin is missing value then error "Rig could not find the managed Ghostty window."

            set targetTab to missing value
            set tabCount to 0
            try
                set tabCount to count of tabs of targetWin
            end try
            repeat with tabIdx from 1 to tabCount
                try
                    set tabRef to tab tabIdx of targetWin
                    if (id of tabRef as text) is expectedTabId then
                        set targetTab to tabRef
                        exit repeat
                    end if
                end try
            end repeat
            if targetTab is missing value then error "Rig could not find the managed Ghostty tab."

            set targetTerm to missing value
            set termCount to 0
            try
                set termCount to count of terminals of targetTab
            end try
            repeat with termIdx from 1 to termCount
                try
                    set termRef to terminal termIdx of targetTab
                    if (id of termRef as text) is expectedTerminalId then
                        set targetTerm to termRef
                        exit repeat
                    end if
                end try
            end repeat
            if targetTerm is missing value then error "Rig could not find the managed Ghostty terminal."

            select tab targetTab
            focus targetTerm

            set output to "{"
            set output to output & "\\"windowId\\":" & my jsonString(id of targetWin)
            set output to output & ",\\"tabId\\":" & my jsonString(id of targetTab)
            set output to output & ",\\"terminalId\\":" & my jsonString(id of targetTerm)
            set output to output & ",\\"workingDirectory\\":" & my jsonString(working directory of targetTerm)
            set output to output & "}"
            return output
        end tell
        """)

        try Task.checkCancellation()
        return try decoder.decode(CreatedGhosttySurface.self, from: Data(json.utf8))
    }

    private func run(script source: String) throws -> String {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw GhosttyControllerError.scriptCompilationFailed
        }

        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? errorInfo.description
            throw GhosttyControllerError.scriptExecutionFailed(message)
        }

        guard let value = result.stringValue else {
            throw GhosttyControllerError.invalidScriptResult
        }

        return value
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")

        return "\"\(escaped)\""
    }

    private static let jsonHandlers = """
    on replaceText(findText, replacementText, sourceText)
        set AppleScript's text item delimiters to findText
        set parts to text items of sourceText
        set AppleScript's text item delimiters to replacementText
        set updatedText to parts as text
        set AppleScript's text item delimiters to ""
        return updatedText
    end replaceText

    on jsonString(valueText)
        if valueText is missing value then set valueText to ""
        set escapedText to valueText as text
        set escapedText to my replaceText("\\\\", "\\\\\\\\", escapedText)
        set escapedText to my replaceText(quote, "\\\\" & quote, escapedText)
        set escapedText to my replaceText(return, "\\\\n", escapedText)
        set escapedText to my replaceText(linefeed, "\\\\n", escapedText)
        set escapedText to my replaceText(tab, "\\\\t", escapedText)
        return quote & escapedText & quote
    end jsonString
    """
}
