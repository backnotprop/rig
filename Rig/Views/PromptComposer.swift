import AppKit
import SwiftUI

// MARK: - Inline reference chip (NSTextAttachment subclass)

/// One inline pill rendered inside the composer. Subclasses NSTextAttachment
/// because we need to carry the URL/metadata alongside the visible glyph and
/// emit the URL when the prompt is assembled. NSTextView treats it as a
/// single character — click selects, backspace deletes — so we get the
/// "Mail.app address chip" feel for free.
final class ReferenceTextAttachment: NSTextAttachment {
    let providerID: String
    let kind: String
    let identifier: String  // "#42", "PR #15"
    let title: String       // not displayed in the chip; kept for tooltip / future use
    let url: URL

    init(providerID: String, kind: String, identifier: String, title: String, url: URL) {
        self.providerID = providerID
        self.kind = kind
        self.identifier = identifier
        self.title = title
        self.url = url
        super.init(data: nil, ofType: nil)
        self.image = Self.renderChipImage(label: identifier)
    }

    required init?(coder: NSCoder) {
        // We never archive these; the composer is a transient UI surface.
        return nil
    }

    private static func renderChipImage(label: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let hPadding: CGFloat = 7
        let vPadding: CGFloat = 1
        let size = NSSize(
            width: ceil(textSize.width) + hPadding * 2,
            height: ceil(textSize.height) + vPadding * 2
        )

        // NSImage(size:flipped:drawingHandler:) re-runs the handler at the
        // correct screen scale, so the chip stays crisp on Retina.
        return NSImage(size: size, flipped: false) { rect in
            let radius = rect.height / 2
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 0.75
            path.stroke()

            (label as NSString).draw(
                at: NSPoint(x: hPadding, y: vPadding),
                withAttributes: attrs
            )
            return true
        }
    }
}

// MARK: - Controller

/// Bridge between SwiftUI state and the NSTextView the composer wraps. Keeps
/// the source of truth (`attributed`) and exposes `insertText` / `insertReference`
/// so panels (saved prompts, references) can paste at the cursor.
@MainActor
final class PromptComposerController: ObservableObject {
    /// Source of truth — owned here so the view can sync without a coordinator
    /// detour. SwiftUI doesn't observe it directly; we publish `isEmpty` for
    /// the placeholder overlay.
    fileprivate var attributed = NSMutableAttributedString()
    @Published private(set) var isEmpty: Bool = true

    fileprivate weak var textView: NSTextView?

    /// Assembles the run-time prompt: text runs emitted as-is, attachment
    /// runs replaced by their URL. Order is preserved (the prose flow the
    /// user composed). Surrounding spaces handled by the auto-insert of
    /// `insertReference`, so we don't second-guess the typed text here.
    func composedString() -> String {
        let snapshot = attributed
        var out = ""
        snapshot.enumerateAttributes(
            in: NSRange(location: 0, length: snapshot.length)
        ) { attrs, range, _ in
            if let ref = attrs[.attachment] as? ReferenceTextAttachment {
                out += ref.url.absoluteString
            } else {
                out += (snapshot.string as NSString).substring(with: range)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when there's no typed text *and* no attachments. Drives the
    /// placeholder overlay.
    func recomputeIsEmpty() {
        let empty = attributed.length == 0
        if empty != isEmpty { isEmpty = empty }
    }

    func insertText(_ text: String) {
        guard let tv = textView else { return }
        let trimmed = text
        let location = currentInsertionPoint(in: tv)

        // Mirror the prior "append with separator" UX so multi-tap stacking
        // of saved prompts reads naturally.
        var insertion = trimmed
        if location > 0 {
            let prev = charAt(location - 1, in: tv) ?? Character(" ")
            let firstIsWhitespace = trimmed.first?.isWhitespace ?? false
            if !prev.isWhitespace, !firstIsWhitespace {
                insertion = " " + insertion
            }
        }

        let attr = NSAttributedString(string: insertion, attributes: defaultTypingAttributes(in: tv))
        replace(in: tv, range: NSRange(location: location, length: 0), with: attr)
        let newLoc = location + (insertion as NSString).length
        tv.setSelectedRange(NSRange(location: newLoc, length: 0))
    }

    func insertReference(provider: any ReferenceProvider, item: ReferenceItem) {
        guard let tv = textView else { return }

        // Extract a short identifier for the chip — "#42" / "PR #15" / etc.
        // ReferenceItem.id is shaped like "issue-42" / "pr-15"; turn that
        // into something readable.
        let identifier = chipIdentifier(for: item, providerID: provider.id)

        // Don't double-attach the same URL.
        if hasAttachment(withURL: item.url) { return }

        let attachment = ReferenceTextAttachment(
            providerID: provider.id,
            kind: deriveKind(from: item.id),
            identifier: identifier,
            title: item.title,
            url: item.url
        )

        var location = currentInsertionPoint(in: tv)

        // Auto-space: if cursor is right after a non-space, insert a leading
        // space so "fix this" + chip reads as "fix this #42" instead of glued.
        if location > 0, let prev = charAt(location - 1, in: tv), !prev.isWhitespace {
            let space = NSAttributedString(string: " ", attributes: defaultTypingAttributes(in: tv))
            replace(in: tv, range: NSRange(location: location, length: 0), with: space)
            location += 1
        }

        let chipString = NSAttributedString(attachment: attachment)
        replace(in: tv, range: NSRange(location: location, length: 0), with: chipString)
        location += chipString.length

        // Trailing space so next attach / typed character isn't glued.
        let trailing = NSAttributedString(string: " ", attributes: defaultTypingAttributes(in: tv))
        replace(in: tv, range: NSRange(location: location, length: 0), with: trailing)
        location += trailing.length

        tv.setSelectedRange(NSRange(location: location, length: 0))
    }

    func clear() {
        guard let tv = textView else { return }
        let full = NSRange(location: 0, length: tv.textStorage?.length ?? 0)
        tv.textStorage?.replaceCharacters(in: full, with: "")
        attributed = NSMutableAttributedString()
        recomputeIsEmpty()
    }

    // MARK: helpers

    private func chipIdentifier(for item: ReferenceItem, providerID: String) -> String {
        // Item id is e.g. "issue-42" or "pr-99". Map to "#42" / "PR #99".
        let parts = item.id.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let number = Int(parts[1]) else { return item.id }
        switch parts[0] {
        case "issue": return "#\(number)"
        case "pr": return "PR #\(number)"
        default: return "#\(number)"
        }
    }

    private func deriveKind(from itemID: String) -> String {
        String(itemID.split(separator: "-").first ?? "")
    }

    private func hasAttachment(withURL url: URL) -> Bool {
        guard let storage = textView?.textStorage else { return false }
        var found = false
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length)
        ) { value, _, stop in
            if let ref = value as? ReferenceTextAttachment, ref.url == url {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func currentInsertionPoint(in tv: NSTextView) -> Int {
        let sel = tv.selectedRange()
        if sel.location == NSNotFound { return tv.textStorage?.length ?? 0 }
        return sel.location + sel.length
    }

    private func charAt(_ idx: Int, in tv: NSTextView) -> Character? {
        guard let storage = tv.textStorage, idx >= 0, idx < storage.length else { return nil }
        let s = (storage.string as NSString).substring(with: NSRange(location: idx, length: 1))
        return s.first
    }

    private func defaultTypingAttributes(in tv: NSTextView) -> [NSAttributedString.Key: Any] {
        var attrs = tv.typingAttributes
        if attrs[.font] == nil {
            attrs[.font] = NSFont.systemFont(ofSize: 12)
        }
        if attrs[.foregroundColor] == nil {
            attrs[.foregroundColor] = NSColor.textColor
        }
        return attrs
    }

    private func replace(in tv: NSTextView, range: NSRange, with attr: NSAttributedString) {
        guard let storage = tv.textStorage else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: attr)
        storage.endEditing()
        attributed = NSMutableAttributedString(attributedString: storage)
        recomputeIsEmpty()
    }
}

// MARK: - SwiftUI wrapper

struct PromptComposer: NSViewRepresentable {
    @ObservedObject var controller: PromptComposerController
    var onSubmit: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsImageEditing = false
        textView.allowsUndo = true
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.textColor = NSColor.textColor
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.onSubmit = { onSubmit?() }

        scroll.documentView = textView
        controller.textView = textView

        // Sync any pre-seeded content.
        if controller.attributed.length > 0 {
            textView.textStorage?.setAttributedString(controller.attributed)
        }
        controller.recomputeIsEmpty()

        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Source of truth flows out of NSTextView edits into the controller —
        // we deliberately don't push the controller's NSAttributedString back
        // here, because that would clobber in-progress typing.
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: PromptComposer
        init(_ parent: PromptComposer) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard
                let tv = notification.object as? NSTextView,
                let storage = tv.textStorage
            else { return }
            parent.controller.attributed = NSMutableAttributedString(attributedString: storage)
            parent.controller.recomputeIsEmpty()
        }
    }
}

// MARK: - NSTextView subclass that surfaces ⌘⏎ → onSubmit

private final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // ⌘ + Return → submit. Plain Return inserts a newline as usual.
        if event.keyCode == 36 /* return */, event.modifierFlags.contains(.command) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }
}
