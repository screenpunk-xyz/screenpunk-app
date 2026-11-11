import Foundation

enum DeviceSwipeTransition {
    /// A short, decisive flick can advance a page. Reversing toward center
    /// near release can instead cancel a drag that crossed the threshold.
    static func direction(translation: CGFloat, velocity: CGFloat, width: CGFloat) -> Int? {
        guard width > 0, abs(translation) >= 12 else { return nil }
        let boundedVelocity = min(1800, max(-1800, velocity))
        let projected = translation + boundedVelocity * 0.14
        let threshold = min(160, width * 0.25)
        guard abs(projected) >= threshold, (projected < 0) == (translation < 0) else { return nil }
        return projected < 0 ? 1 : -1
    }
}
