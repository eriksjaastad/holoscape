# Claude Code per-prompt timestamp injection spike

Status: read-only research spike for card #5880.

## Question

Can a Claude Code session receive the real submission time of every user prompt so Claude can later answer questions such as “when did I last message you?” without Holoscape rewriting terminal input?

## Decision

**Yes, with a Claude Code `UserPromptSubmit` hook.** The hook should add a short factual timestamp as `additionalContext` (or plain stdout) immediately before Claude processes each submitted prompt.

Do not implement this by intercepting Holoscape terminal input, wrapping the interactive CLI’s stdin, or using `PreToolUse`. Those approaches either change interactive CLI behavior, timestamp the wrong event, or couple Holoscape core to one external agent.

This should remain an opt-in Claude Code customization. If Holoscape later manages it, management belongs behind a removable agent-integration plugin; the terminal must remain complete without Claude Code or the hook.

## Evidence

Research was checked on 2026-09-29 against:

- Claude Code `2.1.226` installed at `/opt/homebrew/bin/claude`;
- the official [Hooks reference](https://code.claude.com/docs/en/hooks);
- the official [CLI reference](https://code.claude.com/docs/en/cli-reference);
- `claude --help` from the installed binary.

The official hook contract establishes that:

1. `UserPromptSubmit` runs after the user submits a prompt and before Claude processes it.
2. Its input includes the submitted `prompt`, session id, transcript path, working directory, and permission mode.
3. Exit-zero plain stdout or `hookSpecificOutput.additionalContext` is injected beside the prompt as a system reminder. It is context for the model, not a visible chat entry.
4. The injected value is saved in the session transcript. Resume/continue replays the saved value for historical turns rather than rerunning the hook, which is correct for an event timestamp.
5. A command hook has a 30-second default timeout at this event. If it times out, Claude Code discards the context and still processes the prompt, so the implementation must be local and near-instant.
6. `UserPromptSubmit` can block or annotate a prompt but does not offer a supported prompt-replacement field. Timestamp context should therefore be treated as metadata beside the prompt, not a mutation of user text.

The installed CLI also confirms that stdin streaming (`--input-format stream-json`) is available only with `--print`. Piping or proxying stdin is therefore a non-interactive Agent SDK-style path, not a transparent wrapper for Holoscape’s normal interactive Claude sessions.

## Recommended hook

A dependency-free command hook can print one line using macOS `/bin/date`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/bin/date '+Prompt submitted at %Y-%m-%dT%H:%M:%S%z %Z.'",
            "timeout": 2
          }
        ]
      }
    ]
  }
}
```

Example injected fact:

```text
Prompt submitted at 2026-09-29T02:01:19-0400 EDT.
```

The factual wording is deliberate. Claude’s hook documentation recommends facts rather than imperative or out-of-band-instruction phrasing because instruction-shaped injected text can trigger prompt-injection defenses.

Use the JSON `additionalContext` form instead if future behavior needs structured composition with other metadata. Plain stdout is sufficient for one trusted local timestamp and avoids a `jq`, Python, or custom-binary dependency. Calling `/bin/date` directly also preserves its nonzero exit status instead of printing empty metadata when clock formatting fails.

## Expected behavior

For prompts A, B, and C, Claude’s context receives this sequence:

1. timestamp A beside prompt A;
2. timestamp B beside prompt B;
3. timestamp C beside prompt C.

When prompt C asks when the previous message was sent, Claude can use timestamp B and compare it with timestamp C. Exact elapsed-time arithmetic remains model reasoning, so the most reliable answer is the recorded absolute time plus an approximate relative interval.

Resume behavior preserves historical meaning: timestamp B remains the time prompt B was originally submitted. A resumed session does not relabel old turns with the resume time.

## Limitations and side effects

- **Not visible in the chat UI.** The timestamp is model context, not presentation. Users cannot visually audit it beside each prompt without inspecting debug/transcript data or adding a separate UI feature.
- **Compaction can weaken recall.** The full injected values are stored in the transcript, but old details may no longer be present in the active model context after compaction. A model cannot guarantee exact historical answers for arbitrarily old turns.
- **Small token cost per turn.** One short timestamp is low overhead, but it is still repeated context.
- **Clock authority is local.** Accuracy depends on the machine clock and timezone. The ISO-like offset plus timezone abbreviation avoids an ambiguous local time.
- **Hook failure is fail-open.** A timeout or malformed output lets the prompt continue without timestamp context. This feature is informational, so fail-open is preferable to blocking user input.
- **Hidden system-reminder semantics.** The timestamp has more contextual salience than ordinary visible prompt decoration. Keep it factual and never include untrusted prompt text in the generated output.
- **Claude-only.** Other agents need their own lifecycle hooks. Holoscape should not pretend this is a universal terminal capability.

## Rejected approaches

### `PreToolUse` hook

Wrong event. It runs only when Claude is about to call a tool, after the user prompt has already been processed. Turns with no tool call receive no timestamp, and turns with multiple tools receive duplicates.

### Interactive stdin wrapper or terminal pipe

Not transparent. Claude Code owns terminal line editing in interactive mode, while `--input-format stream-json` requires `--print`. A proxy would need to recreate interactive rendering, permissions, slash commands, paste handling, and session controls. That is an Agent SDK client, not a small Holoscape feature.

### Holoscape PTY input rewriting

Too invasive and brittle. Holoscape would have to detect whether the foreground program is Claude Code, distinguish prompt submission from arbitrary terminal Return keys, and modify bytes sent to the child process. That risks shell correctness and hardwires an external agent into terminal core.

### `--append-system-prompt`

Static at process launch. It can tell Claude how to interpret timestamps but cannot generate a fresh timestamp for each user turn.

### `SessionStart` hook

Useful for the session start or resume time, not individual prompt times. It cannot answer when each prior user message was submitted.

## Product boundary and next step

No Holoscape production code is warranted for this spike. The supported minimal path is a user-scoped Claude Code hook configured outside Holoscape.

If this proves valuable in daily use, create a separate plugin card with these acceptance criteria:

1. opt-in install/remove of the Claude-specific hook;
2. no edits to Claude settings without explicit confirmation and backup;
3. exact read-back verification of the installed hook configuration;
4. an observable health indicator for missed/failed hooks;
5. zero effect on shell, SSH, Codex, or other agent channels;
6. complete Holoscape operation when the plugin is absent.
