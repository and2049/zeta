# Compaction

A long session eventually outgrows the model's context window. Compaction replaces the older part of what the model sees with a summary written by the same model, and keeps the recent part verbatim. Nothing in the session log is rewritten: the summary is appended, and the full history stays available in the log.

## When it happens

- **Automatically**, before a model request, when the estimated context is larger than the model's context window minus `reserveTokens` (at most a quarter of the window, so a small model is not compacted on every request). The window comes from the provider or from `provider.<id>.models.<model>.limit.context` in config; without a known window there is no automatic compaction.
- **When the model rejects a request as too long** for its context (recognized from the service's error, before any of the reply arrived): the request is not logged, the history is compacted (a short one all but its newest message), and the request is rebuilt and sent once more. If that is rejected too, or the compaction fails, the error is logged and the run ends. This needs `enabled` and counts toward the failure limit below. A bare `413` without that wording is not treated as too long.
- **On request**. A compaction request waits in the inbox like a prompt and runs in order; it asks the model for a summary and does not send a reply of its own. A short history is still summarized, all but its newest message.

The context estimate starts from the token usage the provider reported for the latest reply (only replies after the latest summary count) and adds about one token per four characters for what came after it.

If an automatic compaction (threshold or overflow) fails three times in a row, the session stops compacting on its own until the runtime restarts; manual compaction still works. Having nothing to summarize yet does not count as a failure. A summary only counts when the model finished it: one cut off at its output limit is discarded and reported as `compaction.failed`.

## What the model sees

1. zeta walks back from the newest message, keeping about `keepRecentTokens` tokens verbatim (at most half of the window minus the reserve). The kept part starts at a user or assistant message, never at a tool result, so a tool call and its results stay together; when the history ends in a tool batch, the whole batch is kept even if that is more.
2. The older messages since the previous summary are written out as plain text (`[User]: …`, `[Assistant]: …`, `[Assistant tool call]: read({"path":"a.zig"})`, `[Tool result]: …` with tool results cut to 2000 characters) and sent to the model with the previous summary and any instructions, asking for a summary with the sections Goal, Constraints & Preferences, Progress, Key Decisions, Next Steps and Critical Context.
3. The summary is logged as a user message with `"origin": "compaction"`, `firstKeptId` (the first message kept verbatim), `tokensBefore` (the estimated context it replaced) and the `usage` of the summary request.
4. From then on the model sees the summary, then the messages from `firstKeptId` on. A later compaction summarizes from that point, carrying the earlier summary forward.

## Events

`compaction.start` `{reason: "manual" | "threshold" | "overflow"}`, then `compaction.end` `{reason, messageId, tokensBefore}` after the summary's `message.start`/`message.end`, or `compaction.failed` `{reason, error}` (the run goes on without it).

## Settings

```jsonc
{
  "compaction": {
    "enabled": true,          // automatic compaction; manual requests work either way
    "reserveTokens": 16384,   // room kept free for the reply
    "keepRecentTokens": 20000 // recent history kept verbatim
  }
}
```
