/// The AX walk runs only when someone will consume the result — reading
/// the user's screen for nothing is both wasted work and bad optics.
public enum ScreenContextPolicy {
    public static func shouldCapture(
        enabled: Bool,
        cleanupOn: Bool,
        engineBiases: Bool
    ) -> Bool {
        enabled && (cleanupOn || engineBiases)
    }
}
