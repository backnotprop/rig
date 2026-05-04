import AppKit
import Foundation
import SwiftUI

struct Harness: Identifiable, Codable, Equatable {
    let id: String
    var label: String
    var command: String
    var enabled: Bool
    var icon: HarnessIcon
    var tint: HexColor
    var iconInset: Double
    var flags: [String: FlagValue] = [:]

    private enum CodingKeys: String, CodingKey {
        case id, label, command, enabled, icon, tint, iconInset, flags
    }

    init(
        id: String,
        label: String,
        command: String,
        enabled: Bool,
        icon: HarnessIcon,
        tint: HexColor,
        iconInset: Double,
        flags: [String: FlagValue] = [:]
    ) {
        self.id = id
        self.label = label
        self.command = command
        self.enabled = enabled
        self.icon = icon
        self.tint = tint
        self.iconInset = iconInset
        self.flags = flags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.label = try c.decode(String.self, forKey: .label)
        self.command = try c.decode(String.self, forKey: .command)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.icon = try c.decode(HarnessIcon.self, forKey: .icon)
        self.tint = try c.decode(HexColor.self, forKey: .tint)
        self.iconInset = try c.decode(Double.self, forKey: .iconInset)
        // flags is optional in old configs; default to empty.
        self.flags = (try? c.decode([String: FlagValue].self, forKey: .flags)) ?? [:]
    }
}

/// A flag value persisted in `Harness.flags`. Encodes/decodes as the bare value
/// (true/false for bool, "plan" for string) so the JSON stays human-readable.
enum FlagValue: Codable, Equatable {
    case bool(Bool)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.typeMismatch(
                FlagValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected Bool or String")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .string(let s): try c.encode(s)
        }
    }
}

enum HarnessIcon: Codable, Equatable {
    case builtin(name: String)
    case file(URL)

    private enum CodingKeys: String, CodingKey { case type, name, url }
    private enum IconType: String, Codable { case builtin, file }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtin(let name):
            try c.encode(IconType.builtin, forKey: .type)
            try c.encode(name, forKey: .name)
        case .file(let url):
            try c.encode(IconType.file, forKey: .type)
            try c.encode(url, forKey: .url)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(IconType.self, forKey: .type)
        switch type {
        case .builtin:
            self = .builtin(name: try c.decode(String.self, forKey: .name))
        case .file:
            self = .file(try c.decode(URL.self, forKey: .url))
        }
    }
}

struct HexColor: Codable, Equatable, ExpressibleByStringLiteral, Hashable {
    var value: String

    init(_ value: String) { self.value = value }
    init(stringLiteral value: String) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.value = try c.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }

    var color: Color {
        let s = value.hasPrefix("#") ? String(value.dropFirst()) : value
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        switch s.count {
        case 6:
            return Color(
                red: Double((rgb >> 16) & 0xFF) / 255.0,
                green: Double((rgb >> 8) & 0xFF) / 255.0,
                blue: Double(rgb & 0xFF) / 255.0
            )
        case 8:
            return Color(
                red: Double((rgb >> 24) & 0xFF) / 255.0,
                green: Double((rgb >> 16) & 0xFF) / 255.0,
                blue: Double((rgb >> 8) & 0xFF) / 255.0,
                opacity: Double(rgb & 0xFF) / 255.0
            )
        default:
            return .black
        }
    }

    /// Round-trip a SwiftUI `Color` (typically from a `ColorPicker`) into our
    /// hex string. Forces sRGB so the bytes we persist match what the user
    /// picked regardless of the picker's working color space.
    init(color: Color) {
        let nsColor = NSColor(color)
        let rgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
        func byte(_ v: CGFloat) -> Int {
            Int(max(0, min(255, (v * 255).rounded())))
        }
        let r = byte(rgb.redComponent)
        let g = byte(rgb.greenComponent)
        let b = byte(rgb.blueComponent)
        self.init(String(format: "#%02X%02X%02X", r, g, b))
    }
}

extension Harness {
    static let builtinDefaults: [Harness] = [
        Harness(
            id: "pi",
            label: "Pi",
            command: "pi",
            enabled: true,
            icon: .builtin(name: "Pi"),
            tint: HexColor("#000000"),
            iconInset: 0.16
        ),
        Harness(
            id: "claude-code",
            label: "Claude Code",
            command: "claude",
            enabled: true,
            icon: .builtin(name: "Claude"),
            tint: HexColor("#000000"),
            iconInset: 0.16
        ),
        Harness(
            id: "codex",
            label: "Codex",
            command: "codex",
            enabled: true,
            icon: .builtin(name: "Codex"),
            tint: HexColor("#000000"),
            iconInset: 0.16
        ),
        Harness(
            id: "opencode",
            label: "OpenCode",
            command: "opencode",
            enabled: true,
            icon: .builtin(name: "OpenCode"),
            tint: HexColor("#000000"),
            iconInset: 0.24
        ),
    ]
}
