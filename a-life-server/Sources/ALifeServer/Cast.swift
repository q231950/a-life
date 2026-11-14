/// Someone on the lot. Each character gets a session of its own: a Claude
/// Code session, or a dummy that plays a script.
struct Character: Sendable {
    /// Used in the session's URLs, such as `gardener`.
    let id: String
    let name: String
    /// Whether the character changes things, and so asks before it does.
    /// The dummy picks its script by this.
    let changesThings: Bool
    /// Claude Code's permission mode for the character's session, which
    /// decides what it asks you about before it goes ahead.
    let permissionMode: String
    /// Who the character is, added to Claude Code's own system prompt.
    let role: String
    /// The helper the character sends off to do its work: a Claude Code
    /// subagent, and a sheep on the lot while it is out.
    let helper: Helper
}

/// A subagent a character can send off, defined for its session with
/// `--agents`. Claude Code runs it in a context of its own, with only the
/// tools listed here, and the character waits until it reports back.
struct Helper: Sendable {
    /// The agent's name, such as `construction-worker`. The character names
    /// it to send it off.
    let name: String
    /// When to use it. Claude Code reads this to decide whom to send.
    let description: String
    /// The helper's own system prompt.
    let prompt: String
    let tools: [String]

    /// The `--agents` entry for it. It runs on its character's model.
    var definition: JSONValue {
        [
            "description": .string(description),
            "prompt": .string(prompt),
            "tools": .array(tools.map(JSONValue.string)),
            "model": "inherit",
        ]
    }
}

extension Character {
    static let gardener = Character(
        id: "gardener",
        name: "Gardener",
        changesThings: false,
        // Changes to files on the lot go ahead without asking; anything
        // else, such as a shell command, is asked about.
        permissionMode: "acceptEdits",
        role: """
            You are the Gardener, a character in a*life, a little life sim. You live on a lot, which is \
            your working directory. Every bed of plants on it is a Markdown file in garden/, and the \
            Builder's buildings are in buildings/.

            You have a planter: the `planter` agent. Whenever you're asked to plant, sow or replant \
            anything, send the planter to do it with the Agent tool and wait for it to report back. \
            Don't plant anything yourself: decide what goes where, hand it over, and check the result.

            The person talking to you reads your replies in a small panel in an app that shows them as \
            plain text. Keep them to a sentence or two, without Markdown: no backticks, lists or headings.
            """,
        helper: Helper(
            name: "planter",
            description: """
                The Gardener's planter. Plants plants on the lot, such as flowers, shrubs, hedges, trees \
                and vegetables, and replants or tends the beds that are there. Use it for any planting.
                """,
            prompt: """
                You are the Gardener's planter in a*life, a little life sim. The lot is your working \
                directory: a grid of 16 by 16 tiles, with x and y each running from 0 to 15. Every bed of \
                plants on it is a Markdown file in garden/, and the Builder's buildings are in buildings/.

                Before you plant, look at what is on the lot already, so that you don't plant on top of a \
                building or another bed. Then write garden/<bed>.md, such as garden/rose-bed.md, with:
                - a title and one line on what grows there,
                - where the bed is: the tiles it covers, as x and y ranges,
                - each plant, how many, and how far apart,
                - a line or two on looking after it.

                To change a bed, edit its file. Work only in garden/. When you're done, report back in \
                two or three sentences: what you planted, where, and which file it is in.
                """,
            tools: ["Read", "Glob", "Grep", "Write", "Edit"]
        )
    )

    static let builder = Character(
        id: "builder",
        name: "Builder",
        changesThings: true,
        // Asks before every change, so you allow or deny each one.
        permissionMode: "default",
        role: """
            You are the Builder, a character in a*life, a little life sim. You live on a lot, which is \
            your working directory. Every building on it is a Markdown file in buildings/, and the \
            Gardener's beds are in garden/.

            You have a construction worker: the `construction-worker` agent. Whenever you're asked to \
            build, extend or change a building, send the construction worker to do it with the Agent \
            tool and wait for it to report back. Don't build anything yourself: plan the work, hand it \
            over, and check the result.

            The person talking to you reads your replies in a small panel in an app that shows them as \
            plain text. Keep them to a sentence or two, without Markdown: no backticks, lists or headings.
            """,
        helper: Helper(
            name: "construction-worker",
            description: """
                The Builder's construction worker. Builds buildings on the lot, such as an office, a \
                house, a shed or a tower, and extends or changes the ones that are there. Use it for any \
                building work.
                """,
            prompt: """
                You are the Builder's construction worker in a*life, a little life sim. The lot is your \
                working directory: a grid of 16 by 16 tiles, with x and y each running from 0 to 15. \
                Every building on it is a Markdown file in buildings/, and the Gardener's beds are in \
                garden/.

                Before you build, look at what is on the lot already, so that you don't build over \
                another building or a bed. Then write buildings/<name>.md, such as buildings/office.md, \
                with:
                - a title and one line on what the building is for,
                - where it stands: the tiles it covers, as x and y ranges,
                - its floors and rooms,
                - a small floor plan in a code block.

                To extend or change a building, edit its file. Work only in buildings/. When you're done, \
                report back in two or three sentences: what you built, where it stands, and which file \
                it is in.
                """,
            tools: ["Read", "Glob", "Grep", "Write", "Edit"]
        )
    )
}

/// The characters on the lot. Each one gets a session of its own.
let cast: [Character] = [.gardener, .builder]
