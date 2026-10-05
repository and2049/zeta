# Full-screen terminal client

Run `zeta` from a project directory to open a new conversation. The client
attaches to the shared server and uses the same HTTP/SSE API as scripts.

From top to bottom:

- The conversation, which scrolls. A new one shows the logo with the version
  and the keys to get started beside it (the logo is left out when the
  terminal is too small). Your messages sit on a slightly raised
  background; tool calls take one line each with a status mark (✓ done,
  ✗ failed, ○ running). Reasoning and compaction summaries start collapsed
  to one line (`▶ Thinking: …` with the latest words). Each finished turn
  ends with `Worked for 1m 3s · 11:00 AM`, or `Stopped after …` (yellow)
  when interrupted and `Failed after …` (red) on an error.
- While the agent works, a line above the editor says what it is doing and
  for how long: `⠋ Thinking… 12s · Esc to stop` (Working, Thinking,
  Running <tool>, Compacting).
- The editor, between two full-width rules that take the color of the
  thinking level.
- A two-line footer:
  - the directory (bold) and git branch, with status messages on the right;
  - token counts, cost and context use, with the model and thinking level
    (orange) on the right.

Text uses your terminal's colors. The raised background is derived from the
terminal's own background color, which is asked for at startup; terminals
that don't answer get a dark gray. Without `COLORTERM=truecolor` the nearest
of 256 colors is used. There are no themes.

## Settings

The client reads `$XDG_CONFIG_HOME/zeta/tui.jsonc` (usually
`~/.config/zeta/tui.jsonc`) at startup; the server never sees it. Comments
and trailing commas are allowed.

```jsonc
{
  "thinking": "collapsed",   // or "expanded": how reasoning starts
  "compaction": "collapsed", // or "expanded": how compaction summaries start
  "copy": "select"           // or "manual": see "Copying text"
}
```

Ctrl+T flips both while the client runs. A file that can't be used is
reported in the footer and the defaults apply.

## Editing and control

- **Ctrl+C** clears the editor. It never exits, including repeated presses.
- **Ctrl+Q** exits the client; the server remains running.
- **Enter** submits when idle, or steers at the next step boundary while busy.
- **Alt+Enter** queues a follow-up after the current task.
- **Ctrl+J / Shift+Enter** inserts a newline. Ctrl+J works on terminals that
  cannot distinguish Shift+Enter. Keys reported with modifiers (CSI u or
  xterm modifyOtherKeys) are understood, including Alt/Ctrl+Backspace to
  delete a word.
- **Escape** dismisses a picker/completion before aborting an active turn.
- Bracketed paste inserts text without submitting embedded newlines.
- PageUp/PageDown and the mouse wheel scroll; End returns to live output.
- **Ctrl+O** expands/collapses tool output; **Ctrl+T** expands/collapses
  reasoning and compaction summaries.
- **Ctrl+L** opens the model picker without discarding the current draft.
- Typing `/` at the start of the input lists commands and
  [prompt templates](commands.md) above the editor. Typing `@` lists matching
  files. Up and Down move the highlight, and Tab inserts it. Enter inserts it
  too, and runs a command that needs no arguments. Escape closes the list.
  `/name arguments` runs a prompt template; any other unknown `/name` is sent
  as ordinary text.

## Copying text

Drag with the left mouse button over the conversation to select text; the
selection follows the text when you scroll, and dragging past the top or
bottom edge scrolls. A double click selects a word and a triple click a
whole line. Releasing the button copies the selection and the footer says
`Copied to clipboard`.

The copied text is what was written, not the rows as drawn: a line that
was wrapped to fit comes back as one line, and padding and the gutters of
code blocks and quotes are left out.

With `"copy": "manual"` in `tui.jsonc`, releasing the button leaves the
text selected and a right click copies it. Any key removes the selection
(Escape does only that); scrolling keeps it.

The text goes to the terminal's clipboard (OSC 52, which also works over
SSH; tmux needs `set -g set-clipboard on`) and to the desktop's clipboard
program when one is installed: `pbcopy` on macOS, `wl-copy` under
Wayland, `xclip` or `xsel` under X11. Selections over 100 KB only go to
the program. Only the conversation can be selected this way; hold Shift
while dragging for the terminal's own selection anywhere on the screen.

## Links

Web addresses in the conversation are underlined: Markdown links (shown as
`text (address)`) and bare `http://` and `https://` addresses in replies,
your own messages, expanded reasoning and expanded tool output. A click
opens one in your browser (`xdg-open`, or `open` on macOS) and the footer
says which site was opened. Other kinds of address, such as `file:` or
`mailto:`, are shown but not opened.

Links are also marked for the terminal (OSC 8), so terminals that support
it show the address on hover, and their own way of opening a link (often
Shift+click) works too.

## Sessions and models

Use `/new` for a new conversation and `/resume` for the session picker.
`/model` selects a model for the next run; an active run keeps its current
configuration. Selection is persisted across server restarts.
Only connected providers and explicitly configured endpoints appear in the
model picker. Use `/connect` to add another provider; keyless local endpoints
use their configured model definitions.
`/thinking` picks the thinking level for the next run (`/thinking high` sets
it directly; `auto` returns to the configured default).
`/rename` changes the session title. `/help` lists the keys.

`/cd <dir>` moves the conversation to another directory's project (its git
root, or the directory itself): the next turn uses that project's config,
instructions, tools and MCP servers, and the conversation gets a note saying
so. `~` and relative paths work; while you type the path, its subdirectories
are listed (Tab goes into one, Enter moves). A directory in the same project
changes nothing. Stop a running turn first.

`@file` completion inserts a path reference for the agent to read using its
normal tools. Images are explicit attachments and require an image-capable
model.

## Questions from plugins

When a plugin asks something (see [permissions](permissions.md#questions)),
the question replaces the editor until it is answered; events keep arriving
meanwhile. The client shows its own session's questions and those for the
project with no session. Escape declines any of them.

- A yes/no question: **y**, **1** or Enter answers yes; **n** or **2** no.
- A choice: Up and Down move, Enter picks; **1**–**9** pick directly.
- Text: type it and press Enter; secret text shows as dots.
- A form: one field at a time, Enter moves on; a value that does not fit
  stays with a note.

Notices from plugins appear in the conversation.

## Connecting a provider

Use `/connect` to search for a provider, then select a login method. API keys
are entered in a masked editor and sent directly to the server, never as a
conversation message. OpenAI also supports ChatGPT browser and device-code
login: the browser flow opens the URL automatically when possible; Enter
opens it again. For device login, follow the URL and instructions displayed
in the terminal (Enter opens that URL too). If browser launch fails, the URL
remains visible. On a narrow
terminal, use Left/Right to page through the entire URL and Up/Down to page
through the instructions/code. The client
checks completion in the background; Escape cancels the login flow. Your
conversation draft remains in the editor while the picker is open. After
connecting, the refreshed model picker opens automatically.
Ctrl+Q also attempts to cancel a known pending login before exiting (without
starting a server). If the login request has not returned its flow ID yet,
the server's login timeout eventually expires it.

## Recovery

The client subscribes to events before loading session snapshots. Reconnection
restores completed messages, the current streaming draft, pending inputs, and
the questions plugins still have open for the session. Server restart restores conversations without
automatically restarting interrupted turns.

`/fork` continues in a copy of the current session (the original stays as it
is); `/resume` switches between them.

`/compact [focus]` summarizes the older part of the conversation (see
[compaction](compaction.md)); the status line reports when it starts, ends or
fails.

`/undo` restores the files the latest reply changed.

`/reload` reloads plugins for the project (see the [protocol](protocol.md)); the
status line reports any that kept their previous version. `/mcp` shows the
project's [MCP servers](mcp.md) in the status line and `/mcp <name>` connects
one again; `/extensions` and `/extensions <name>` do the same for
[extensions](extensions.md). Commands from extensions appear in `/` completion
beside prompt templates.

`/pending` opens waiting inputs. Enter removes a waiting input from the server
and restores it to the editor, including images; Delete removes it without
restoring. An input already promoted into execution cannot be removed. Restored
input is only sent again when you submit it. Editor drafts and attachments stay
with their session when switching between conversations.

Terminal modes are restored on exit. Software flow control is disabled while
the TUI runs so Ctrl+Q reaches the application.
