/// A character's way to work and back, as a front end decides it: into the
/// office and up the lift to its room when it starts working, and back down
/// and out once it's done. It doesn't walk anyone anywhere; it says which
/// way the character is headed and when it steps into and out of the lift.
///
/// A character in the middle of its work can look done for a moment, as
/// between the server saying a request was answered and saying the
/// character is running again. So it only heads out once it has looked done
/// for `settleTime`, and a character at its desk stays put through anything
/// shorter: waiting for you, your answer, its helpers coming and going.
public struct Commute: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// On the lot: on its spot on the lawn, or on its way there.
        case outside
        /// Walking to the lift.
        case goingIn
        /// In the lift on its way up, out of sight.
        case goingUp
        /// At its desk.
        case atDesk
        /// In the lift on its way down, out of sight.
        case goingDown
    }

    /// What the character does on a step, besides walking.
    public enum Step: Equatable, Sendable {
        /// Steps into the lift at the bottom, out of sight.
        case enterLift
        /// Appears at its desk.
        case appearAtDesk
        /// Leaves its desk for the lift, out of sight.
        case leaveDesk
        /// Steps out of the lift into the lobby, on its way out.
        case appearAtLift
    }

    /// How long a ride in the lift takes, in seconds.
    public static let rideDuration: Float = 1.5
    /// How long a character has to look done before it heads out, in seconds.
    public static let settleTime: Float = 1

    public private(set) var phase = Phase.outside
    /// How long it has been in its current phase, in seconds.
    private var elapsed: Float = 0
    /// How long it has looked done for, in seconds.
    private var offWork: Float = 0

    public init() {}

    /// Where it's headed when it walks: to the lift, or else to the lawn.
    public var isHeadingIn: Bool { phase == .goingIn }

    /// Moves on by `deltaTime` seconds, for a character that is working (or
    /// waiting for you in the middle of it) if `isAtWork`, and standing at
    /// the lift if `isAtLift`. Returns what it does, if anything.
    public mutating func advance(by deltaTime: Float, isAtWork: Bool, isAtLift: Bool) -> Step? {
        elapsed += deltaTime
        offWork = isAtWork ? 0 : offWork + deltaTime
        let isDone = offWork >= Self.settleTime

        switch phase {
        case .outside:
            if isAtWork { enter(.goingIn) }
        case .goingIn:
            if isDone {
                enter(.outside)
            } else if isAtLift {
                enter(.goingUp)
                return .enterLift
            }
        case .goingUp:
            if elapsed >= Self.rideDuration {
                enter(.atDesk)
                return .appearAtDesk
            }
        case .atDesk:
            if isDone {
                enter(.goingDown)
                return .leaveDesk
            }
        case .goingDown:
            if isAtWork {
                enter(.goingUp) // back to work before it's even out of the lift
            } else if elapsed >= Self.rideDuration {
                enter(.outside)
                return .appearAtLift
            }
        }
        return nil
    }

    private mutating func enter(_ phase: Phase) {
        self.phase = phase
        elapsed = 0
    }
}
