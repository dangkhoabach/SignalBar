import AppKit
import SwiftUI

/// A real `NSSearchField`, not a `TextField` dressed up to look like one.
///
/// The hand-rolled `HStack { Image("magnifyingglass"); TextField(...) }`
/// version never quite matched the system search field (see reference
/// screenshot from a stock macOS app): a plain `TextField` wrapped in custom
/// content isn't a control the system recognizes for toolbar purposes, so it
/// only ever got a generic Liquid Glass backing behind arbitrary content —
/// not the actual search-field bezel, icon inset, and rounding a real
/// `NSSearchField` draws itself. Bridging the genuine control sidesteps that
/// entirely: it looks identical because it *is* the same control.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.controlSize = .large
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
