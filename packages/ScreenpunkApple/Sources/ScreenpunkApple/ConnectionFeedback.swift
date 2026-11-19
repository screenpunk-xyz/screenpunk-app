import SwiftUI

/// Acknowledges connection feedback without changing credentials, permissions,
/// pairing progress, entered values or the operation's recovery controls.
struct ConnectionFeedback: View {
    let text: String
    let onDismiss: () -> Void
    init(_ text: String, onDismiss: @escaping () -> Void) {
        self.text = text; self.onDismiss = onDismiss
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).foregroundStyle(.secondary).textSelection(.enabled)
            Button("Dismiss", action: onDismiss)
                .accessibilityLabel("Dismiss message")
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, onDismiss)
    }
}
