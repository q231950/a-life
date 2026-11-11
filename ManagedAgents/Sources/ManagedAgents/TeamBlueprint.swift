import Foundation

/// What gets created, once, the first time the app runs with an API key: a
/// coordinator agent that can delegate to teammates, and a cloud environment
/// for their shared sandbox. Both are stored objects; later launches reuse
/// their IDs.
public struct TeamBlueprint: Equatable, Sendable {
    public var agentName: String
    public var agentDescription: String
    public var model: String
    public var system: String
    /// Dynamic workflows let the coordinator fan a large job out to many
    /// agents at once. Every agent in a run uses tokens; set to `false` to keep
    /// the team to plain delegation.
    public var workflowsEnabled: Bool
    public var environmentName: String
    /// Hard spend cap for each session, in US cents. The session pauses when it
    /// is reached. `nil` creates sessions without a cap.
    public var sessionBudgetCents: Int?

    public init(
        agentName: String,
        agentDescription: String,
        model: String,
        system: String,
        workflowsEnabled: Bool,
        environmentName: String,
        sessionBudgetCents: Int?
    ) {
        self.agentName = agentName
        self.agentDescription = agentDescription
        self.model = model
        self.system = system
        self.workflowsEnabled = workflowsEnabled
        self.environmentName = environmentName
        self.sessionBudgetCents = sessionBudgetCents
    }

    public static let `default` = TeamBlueprint(
        agentName: "Team lead",
        agentDescription: "Leads a small team in a shared sandbox. A copy can be spawned to own one self-contained piece of a larger request.",
        model: "claude-opus-5-5",
        system: """
            You lead a small team of agents working in a shared sandbox. \
            When a request splits into independent pieces, delegate each piece to a teammate: \
            a copy of yourself, or an agent you define with a short descriptive name. \
            Give every teammate one self-contained task with the paths and constraints it needs, \
            then check and combine their reports yourself. \
            Do small, single-step requests yourself; delegating those only adds a round trip. \
            When a request has more pieces than a handful of teammates can cover, \
            start a workflow run that works through them in parallel. \
            Keep your replies short: they are shown in a small overlay.
            """,
        workflowsEnabled: true,
        environmentName: "a-life-sandbox",
        sessionBudgetCents: 500
    )

    var agentBody: JSONValue {
        [
            "name": .string(agentName),
            "description": .string(agentDescription),
            "model": .string(model),
            "system": .string(system),
            "tools": [
                [
                    "type": "agent_toolset_20260401",
                    // `auto`: the server allows calls it judges safe, denies
                    // high-risk ones, and asks the client about the rest.
                    "default_config": ["permission_policy": ["type": "auto"]],
                    "configs": [
                        ["name": "web_fetch", "enabled": false],
                        ["name": "web_search", "enabled": false],
                    ],
                ],
            ],
            "multiagent": [
                "type": "multiagent_20261001",
                "subagents": ["type": "enabled", "predefined_agents": [["type": "self"]]],
                "workflows": ["type": workflowsEnabled ? "enabled" : "disabled"],
            ],
        ]
    }

    var environmentBody: JSONValue {
        [
            "name": .string(environmentName),
            "config": [
                "type": "cloud",
                "networking": ["type": "limited", "allow_package_managers": true, "allow_mcp_servers": false],
            ],
        ]
    }
}
