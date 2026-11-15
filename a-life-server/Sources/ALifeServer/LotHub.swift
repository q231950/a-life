import ALifeAPI
import Foundation

/// What is on the lot, and the clients following it.
///
/// The characters build and plant by writing files in the lot's
/// `buildings/` and `garden/`, so the hub looks at them every so often (see
/// `LotSurvey`). Each time something on the lot changes, the whole lot goes
/// out to every open stream, with the next revision, and `lot.md` in the
/// lot is brought up to date for the helpers to read. The first look is
/// revision 1, so a client can tell the lot it is sent from not having
/// heard yet.
actor LotHub {
    /// The lot's directory, or `nil` for a lot that stays empty.
    let directory: URL?
    private(set) var lot = Lot()
    private var streams: [UUID: AsyncStream<Lot>.Continuation] = [:]
    private var watching: Task<Void, Never>?
    private var hasSurveyed = false

    init(directory: URL?) {
        self.directory = directory
    }

    /// Looks at the lot again, and tells the clients if anything on it changed.
    func survey() {
        guard let directory else { return }
        let (items, problems) = LotSurvey.survey(LotSurvey.entries(in: directory))
        if !hasSurveyed || items != lot.items || problems != lot.problems {
            hasSurveyed = true
            lot = Lot(revision: lot.revision + 1, items: items, problems: problems)
            for stream in streams.values {
                stream.yield(lot)
            }
        }
        writeReport(in: directory)
    }

    /// Surveys the lot every `interval` until `stop()`.
    func watch(every interval: Duration) {
        watching?.cancel()
        watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.survey()
            }
        }
    }

    /// A stream of the lot as it is now, then as it is after each change.
    func subscribe() -> AsyncStream<Lot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Lot>.makeStream()
        continuation.yield(lot)
        streams[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.forget(id) }
        }
        return stream
    }

    /// Stops watching the lot and ends the open streams.
    func stop() {
        watching?.cancel()
        watching = nil
        for stream in streams.values {
            stream.finish()
        }
        streams = [:]
    }

    /// Writes `lot.md`, unless it says that already.
    private func writeReport(in directory: URL) {
        let file = directory.appendingPathComponent(LotSurvey.reportName)
        let report = LotSurvey.report(lot)
        guard (try? String(contentsOf: file, encoding: .utf8)) != report else { return }
        try? report.write(to: file, atomically: true, encoding: .utf8)
    }

    private func forget(_ id: UUID) {
        streams[id] = nil
    }
}
