import SwiftUI
import UIKit

/// Recognizers live on the parent hosting view so one-finger web content stays interactive.
struct DeviceGestures: UIViewRepresentable {
    var began: () -> Void
    var ended: () -> Void
    var cancelled: () -> Void
    var swipe: (Int) -> Void
    var settings: () -> Void
    func makeUIView(context: Context) -> GestureAnchor {
        let view = GestureAnchor(); view.isUserInteractionEnabled = false
        view.configure = { parent in context.coordinator.attach(to: parent) }
        return view
    }
    func updateUIView(_ uiView: GestureAnchor, context: Context) { context.coordinator.owner = self }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    static func dismantleUIView(_ uiView: GestureAnchor, coordinator: Coordinator) { coordinator.detach() }
    final class GestureAnchor: UIView {
        var configure: ((UIView) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); if let window { configure?(window) } }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: DeviceGestures
        weak var parent: UIView?
        var recognizers: [UIGestureRecognizer] = []
        init(_ owner: DeviceGestures) { self.owner = owner }
        func attach(to view: UIView) {
            guard parent !== view else { return }; detach(); parent = view
            let talk = UILongPressGestureRecognizer(target: self, action: #selector(talk(_:)))
            talk.numberOfTouchesRequired = 3; talk.minimumPressDuration = 0.3; talk.allowableMovement = 80
            let menu = UILongPressGestureRecognizer(target: self, action: #selector(menu(_:)))
            menu.numberOfTouchesRequired = 2; menu.minimumPressDuration = 5
            // Keep tracking both fingers even while the underlying page pans.
            menu.allowableMovement = .greatestFiniteMagnitude
            menu.cancelsTouchesInView = false
            let left = UISwipeGestureRecognizer(target: self, action: #selector(page(_:))); left.direction = .left; left.numberOfTouchesRequired = 2
            let right = UISwipeGestureRecognizer(target: self, action: #selector(page(_:))); right.direction = .right; right.numberOfTouchesRequired = 2
            recognizers = [talk, menu, left, right]
            recognizers.forEach { $0.delegate = self; view.addGestureRecognizer($0) }
        }
        func detach() { recognizers.forEach { parent?.removeGestureRecognizer($0) }; recognizers = []; parent = nil }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // Reject at touch begin, rather than checking visibility when the
            // action fires: dismissal can remove the status card mid-gesture.
            !DeviceStatusInteractionRegions.contains(touch)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc func talk(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state { case .began: owner.began(); case .ended: owner.ended(); case .cancelled, .failed: owner.cancelled(); default: break }
        }
        @objc func menu(_ gesture: UILongPressGestureRecognizer) { if gesture.state == .began { owner.settings() } }
        @objc func page(_ gesture: UISwipeGestureRecognizer) { if gesture.state == .ended { owner.swipe(gesture.direction == .left ? 1 : -1) } }
    }
}

/// Weak view boundaries work even when SwiftUI hosts the card's buttons and
/// ScrollView as siblings rather than descendants of the representable view.
private enum DeviceStatusInteractionRegions {
    private static let views = NSHashTable<UIView>.weakObjects()
    static func register(_ view: UIView) { views.add(view) }
    static func unregister(_ view: UIView) { views.remove(view) }
    static func contains(_ touch: UITouch) -> Bool {
        views.allObjects.contains { view in
            guard let window = view.window, touch.view?.window === window,
                  !view.isHidden, view.alpha > 0, !view.bounds.isEmpty else { return false }
            return view.bounds.contains(touch.location(in: view))
        }
    }
}

/// The card's only dismissal gesture is a horizontal, single-finger swipe.
/// Vertical scrolling remains simultaneous within the card's own ScrollView.
struct DeviceStatusInteractionRegion: UIViewRepresentable {
    let presentationID: UUID?
    let dismissalEnabled: Bool
    let onDismiss: (UUID) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }
    func makeUIView(context: Context) -> BoundaryView {
        let view = BoundaryView(); view.isUserInteractionEnabled = false
        DeviceStatusInteractionRegions.register(view)
        view.configure = { [weak coordinator = context.coordinator] boundary in coordinator?.attach(boundary) }
        return view
    }
    func updateUIView(_ view: BoundaryView, context: Context) { context.coordinator.owner = self }
    static func dismantleUIView(_ view: BoundaryView, coordinator: Coordinator) {
        DeviceStatusInteractionRegions.unregister(view); coordinator.detach()
    }
    final class BoundaryView: UIView {
        var configure: ((BoundaryView) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); configure?(self) }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: DeviceStatusInteractionRegion
        private weak var boundary: BoundaryView?
        private weak var window: UIWindow?
        private var recognizers: [UISwipeGestureRecognizer] = []
        private var capturedIDs: [ObjectIdentifier: UUID] = [:]
        init(owner: DeviceStatusInteractionRegion) { self.owner = owner }
        func attach(_ boundary: BoundaryView) {
            guard self.boundary !== boundary || window !== boundary.window else { return }
            detach(); self.boundary = boundary; window = boundary.window
            guard let window else { return }
            recognizers = [UISwipeGestureRecognizer(target: self, action: #selector(dismissMessage(_:))), UISwipeGestureRecognizer(target: self, action: #selector(dismissMessage(_:)))]
            recognizers[0].direction = .left; recognizers[1].direction = .right
            for recognizer in recognizers {
                recognizer.numberOfTouchesRequired = 1
                recognizer.cancelsTouchesInView = true
                recognizer.delegate = self
                window.addGestureRecognizer(recognizer)
            }
        }
        func detach() {
            recognizers.forEach { window?.removeGestureRecognizer($0) }
            recognizers = []; capturedIDs = [:]; boundary = nil; window = nil
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard owner.dismissalEnabled, let id = owner.presentationID,
                  let boundary, let window = boundary.window, touch.view?.window === window,
                  boundary.bounds.contains(touch.location(in: boundary)) else { return false }
            // Keep the identity at touch begin. A later completion, even with
            // identical text, must not be dismissed by this older swipe.
            capturedIDs[ObjectIdentifier(gestureRecognizer)] = id
            return true
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer
        }
        @objc private func dismissMessage(_ gesture: UISwipeGestureRecognizer) {
            guard gesture.state == .ended, owner.dismissalEnabled,
                  let id = capturedIDs.removeValue(forKey: ObjectIdentifier(gesture)) else { return }
            owner.onDismiss(id)
        }
    }
}
