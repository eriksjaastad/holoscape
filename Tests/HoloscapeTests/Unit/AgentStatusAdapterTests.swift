import XCTest
@testable import Holoscape

final class AgentStatusAdapterTests: XCTestCase {
    func testClaudePermissionPromptMapsToNeedsApproval() throws {
        let state = try XCTUnwrap(AgentStatusAdapter().persistentState(
            tool: "claude",
            event: "permission_prompt",
            reason: "Claude asks to run a command",
            updatedAt: Date(timeIntervalSince1970: 1_800_000_010)
        ))

        XCTAssertEqual(state.kind, .needsApproval)
        XCTAssertEqual(state.source, .agentAdapter)
        XCTAssertEqual(state.reason, "Claude asks to run a command")
        XCTAssertNil(state.recoveryAction)
    }

    func testCodexCompletionMapsToSameReadyStateAsClaudeIdlePrompt() throws {
        let adapter = AgentStatusAdapter()

        let claude = try XCTUnwrap(adapter.persistentState(tool: "claude-code", event: "idle_prompt"))
        let codex = try XCTUnwrap(adapter.persistentState(tool: "codex", event: "response_completed"))

        XCTAssertEqual(claude.kind, .ready)
        XCTAssertEqual(codex.kind, .ready)
        XCTAssertEqual(claude.source, .agentAdapter)
        XCTAssertEqual(codex.source, .agentAdapter)
    }

    func testCodexApprovalPromptMapsToNeedsApprovalWithoutClaudeSpecialCase() throws {
        let state = try XCTUnwrap(AgentStatusAdapter().persistentState(
            tool: "codex-cli",
            event: "awaiting_approval"
        ))

        XCTAssertEqual(state.kind, .needsApproval)
        XCTAssertTrue(state.reason?.contains("codex") == true)
    }

    func testOpenClawDetachedSessionMapsToRecoverableStale() throws {
        let state = try XCTUnwrap(AgentStatusAdapter().persistentState(
            tool: "openclaw",
            event: "detached"
        ))

        XCTAssertEqual(state.kind, .stale)
        XCTAssertEqual(state.source, .agentAdapter)
        XCTAssertEqual(state.recoveryAction, .recreateBrokerSession)
    }

    func testUnknownEventIsIgnoredRatherThanInventingState() {
        XCTAssertNil(AgentStatusAdapter().persistentState(tool: "codex", event: "surprised"))
    }
}
