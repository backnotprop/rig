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
