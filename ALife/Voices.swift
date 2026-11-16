import ALifeClient
#if os(iOS)
import AVFoundation
#endif
import Foundation
import Observation
import PhononTTS

/// The characters' voices: Phonon text to speech, on this device. The
/// model comes from the server, which offers it for the app to download
/// once (see Voices in a-life-server/README.md), and is kept in
/// Application Support from then on.
@MainActor
@Observable
final class Voices: SpeechEngine {
    enum Status: Equatable {
        /// Not looked for yet.
        case off
        /// Fetching the model from the server, this far along (0 to 1).
        case downloading(Double)
        /// Getting the model ready, which takes longer the first time.
        case loading
        /// Ready to speak.
        case ready
        /// No model to speak with, and why.
        case unavailable(String)
    }

    private(set) var status = Status.off
    /// The last line said out loud, if any has been since the app started.
    private(set) var lastSaid: String?
    /// Why the last line wasn't said, if it wasn't.
    private(set) var problem: String?

    /// Voices from the model's catalogue that sound like ordinary people, in
    /// the order they're handed out to the characters. Any others the model
    /// has come after them.
    private static let preferred = [
        "Maeve", "Edwin", "Juniper", "Hugh", "Freya", "Miles", "Imogen", "Teddy", "Delia", "Trevor",
    ]

    @ObservationIgnored private var tts: Phonon?
    @ObservationIgnored private var player: PhononPlayer?
    @ObservationIgnored private var voiceNames: [String] = []
    @ObservationIgnored private var playback: Task<Void, Never>?
    @ObservationIgnored private var loading: Task<Void, Never>?

    /// Fetches the model from `server`, unless this device has it already,
    /// and loads it. Once loaded, it stays loaded.
    func load(from server: URL?) {
        guard tts == nil, loading == nil else { return }
        loading = Task {
            await prepare(from: server)
            loading = nil
        }
    }

    private func prepare(from server: URL?) async {
        var models: URL?
        if let server {
            status = .downloading(0)
            do {
                models = try await PhononModels.download(from: server) { [weak self] fraction in
                    Task { @MainActor in
                        if case .downloading = self?.status { self?.status = .downloading(fraction) }
                    }
                }
            } catch {
                // A model fetched before still does, if the server is away.
                if !PhononModels.isInstalled() {
                    status = .unavailable("The server has no voice model to download (\(Self.describe(error))).")
                    return
                }
            }
        }
        if models == nil, PhononModels.isInstalled() {
            models = PhononModels.defaultDirectory
        }
        guard let models else {
            status = .unavailable("There's no server to download the voice model from.")
            return
        }

        status = .loading
        do {
            let tts: Phonon
            do {
                tts = try await Phonon.load(models: models, language: .english)
            } catch {
                // Slower, but there's a CPU on every device, if the Neural
                // Engine won't take the model.
                tts = try await Phonon.load(models: models, language: .english, computeUnit: .cpu)
            }
            // Made now, so a device that can't play sound says so at once.
            _ = try freshPlayer()
            voiceNames = Self.preferred.filter(tts.voices.contains) + tts.voices.filter { !Self.preferred.contains($0) }
            self.tts = tts
            status = .ready
        } catch {
            status = .unavailable("The voice model didn't load: \(Self.describe(error))")
        }
    }

    /// What went wrong, in Phonon's own words where it has some.
    private static func describe(_ error: Error) -> String {
        (error as? PhononError)?.description ?? error.localizedDescription
    }

    // MARK: SpeechEngine

    func say(_ text: String, voice: Int) async {
        guard let tts, !voiceNames.isEmpty else { return }
        let name = voiceNames[voice % voiceNames.count]
        let playback = Task {
            do {
                let player = try freshPlayer()
                if tts.voice != name { try await tts.setVoice(name) }
                var seconds = 0.0
                let started = ContinuousClock.now
                for try await chunk in tts.stream(text) {
                    player.enqueue(chunk)
                    seconds += Double(chunk.count) / Phonon.sampleRate
                }
                // Speech is made much faster than it plays: wait for the
                // last of it to be heard before the next line.
                try await Task.sleep(until: started + .seconds(seconds), clock: .continuous)
                lastSaid = text
                problem = nil
            } catch {
                // Stopped, which is no problem, or the line couldn't be
                // said; either way, on to the next.
                if !Task.isCancelled, !(error is CancellationError) {
                    problem = "The last line wasn't said: \(Self.describe(error))"
                }
            }
        }
        self.playback = playback
        await playback.value
        if self.playback == playback { self.playback = nil }
    }

    /// A new player for the next line, with the device's audio woken up for
    /// it. On iOS, the system stops a player's audio engine whenever the
    /// app's sound is interrupted or rerouted (a call, Siri, headphones,
    /// going to the background, RealityKit setting up its own sound), and a
    /// stopped one plays nothing without a word, so each line starts afresh.
    private func freshPlayer() throws -> PhononPlayer {
        #if os(iOS)
        // Played alongside whatever else is playing, rather than stopping
        // it, and heard with the silent switch on.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: .mixWithOthers)
        try session.setActive(true)
        #endif
        player = nil // the old one's engine stops before the new one's starts
        let player = try PhononPlayer(configureSession: false)
        self.player = player
        return player
    }

    func stop() {
        playback?.cancel()
        playback = nil
        player?.stop()
    }
}
