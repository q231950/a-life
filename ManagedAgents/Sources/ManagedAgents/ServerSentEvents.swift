import Foundation

struct ServerSentEvent: Equatable {
    var event: String?
    var data: String
}

/// Incremental parser for a `text/event-stream` body. Feed it bytes as they
/// arrive; it returns the events completed so far.
struct ServerSentEventParser {
    private var buffer = Data()
    private var event: String?
    private var dataLines: [String] = []

    mutating func feed(_ bytes: Data) -> [ServerSentEvent] {
        buffer.append(bytes)
        var events: [ServerSentEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if line.last == 0x0D { line = line.dropLast() }
            if let completed = consume(String(decoding: line, as: UTF8.self)) {
                events.append(completed)
            }
        }
        return events
    }

    private mutating func consume(_ line: String) -> ServerSentEvent? {
        if line.isEmpty {
            defer { event = nil; dataLines = [] }
            return dataLines.isEmpty ? nil : ServerSentEvent(event: event, data: dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil } // comment, used as a heartbeat

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }
}
