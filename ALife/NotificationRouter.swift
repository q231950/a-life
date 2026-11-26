import ALifeClient
import Observation

/// Where a tapped notification leads: the character it is about, and the
/// reply to open its conversation at. The app delegate hands it the
/// notification's route, whether the app was open, in the background or
/// launched by the tap, and `WorldView` follows it once that character is
/// on the lot. Only the iPhone and iPad app gets notifications.
@MainActor
@Observable
final class NotificationRouter {
    /// A reply to show in a character's conversation.
    struct Reply: Equatable {
        /// The character's session id.
        let session: String
        /// The reply's message id.
        let message: String
    }

    /// A tapped notification, until it has been followed.
    var pending: PushRoute?
    /// The reply the conversation scrolls to once it has it from the
    /// server, rather than to the latest.
    var reply: Reply?
}
