import Observation

/// Re-arming wrapper around `withObservationTracking`. `onChange` runs on the main actor
/// *after* the change has landed, then tracking is re-armed.
@MainActor
func observeChanges(_ read: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
    withObservationTracking {
        read()
    } onChange: {
        Task { @MainActor in
            onChange()
            observeChanges(read, onChange: onChange)
        }
    }
}
