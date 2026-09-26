# vim-pi-chat

A chat window for the [pi coding agent](https://github.com/earendil-works/pi)
inside classic Vim (no GUI, no nvim, no Node.js runtime needed by Vim itself —
it just speaks to the `pi` CLI).

```
┌────────────────────────────────────────────┬─────────────────────────────┐
│                                            │ ── pi chat ──               │
│   your code in the main window             │ Type at the bottom line     │
│                                            │ ...                         │
│                                            │ ❯ fix the failing test      │
│                                            │   ⚙ bash npm test           │
│                                            │   ✓ bash                    │
│                                            │ The test failed on line 42  │
│                                            │ because...                  │
│                                            │ ──────────────────────────  │
└────────────────────────────────────────────┴─────────────────────────────┘
```

## How it works

The plugin spawns `pi --mode rpc` as a background job
(`jobstart`/`ch_sendraw`). RPC mode is a strict JSON-lines protocol over
stdin/stdout (see pi's `docs/rpc.md`): commands go in as one JSON object per
line, events come back as one JSON object per line. The plugin:

- buffers stdout lines and drains them on a `timer_start` tick, so output
  never interrupts you mid-keystroke;
- renders `text_delta` deltas incrementally (line-buffered), tool executions
  as `⚙ …` / `✓ …` / `✗ …` lines, and your prompts as `❯ …`;
- answers extension UI requests: `notify` renders as an in-chat transcript
  line with a level marker (ℹ/⚠/⛔), `confirm`/`select`/`input` use native Vim
  dialogs, and `editor` opens a scratch buffer.

The conversation buffer is a plain text buffer. Everything is the transcript
except the `❯` prompt block at the bottom: type there, `<CR>` sends, and
`<C-CR>` opens a continuation line so prompts can span
multiple lines. The transcript above the prompt is guarded by an autocmd:
any interactive edit is detected and reverted (the buffer stays modifiable
so the plugin can keep appending to it, and yank/visual still work).

## Install

```sh
git clone https://github.com/galeone/vim-pi-chat ~/.vim/pack/plugins/start/vim-pi-chat
```

(or any path under `pack/*/start`, a pathogen/tp plugin dir, or drop
`plugin/pi_chat.vim` in your runtimepath; with a plugin manager you can add
`Plug 'galeone/vim-pi-chat'` / `use 'galeone/vim-pi-chat'` / add to your
`vim.plug` block as usual)

Requirements:

- Vim **8.2+** compiled with `+job +channel` (`vim --version | grep job`)
- the `pi` CLI installed and on `$PATH`
- `pi auth` done beforehand (the plugin never handles credentials)

## Usage

| Command | Effect |
| --- | --- |
| `:PiOpen` | open the chat **and** the thinking panel (chat in a vertical split on the right by default) |
| `:PiOpen <message>` | open (chat + thinking) and immediately send `<message>` |
| `:PiSend <text>` | send a prompt (no text: jump to the chat and start typing) |
| `:PiAbort` | abort the current run (`{"type":"abort"}`) |
| `:PiModel <pattern>` | switch model, e.g. `:PiModel anthropic/claude-sonnet-4-5` |
| `:PiClear` | start a fresh session (restarting the agent process with a new session id, so extensions never see a replaced session) |
| `:PiThinking` | toggle a small read-only panel below the chat (opened automatically with `:PiOpen`) streaming the model's thinking live, auto-scrolled to the newest line (height: `g:pi_chat_thinking_height`). Thoughts accumulate even while hidden, under a `──── prompt` marker per turn, so opening it later shows past thinking; `:PiClear` / `:PiClose` wipe it |
| `:PiClose` | stop the agent and close (tear down) the chat |
| `:PiFile [path]` | show or set the context file (see below) |
| `<leader>pi` | `:PiOpen` (default mapping, set `g:pi_chat_map` to change) |

In the chat buffer: `A` (or `i`) jumps to the `❯` prompt and enters insert
mode, `<CR>` sends (multi-line: continuation lines are joined), and `<C-c>`
aborts the current run. While pi is generating a turn, typing on the prompt
is ignored (the prompt glyph is hidden and the input line is blanked — you
see an in-chat `⏳ pi is working…` line instead — and the statusline
spinner shows pi is working) — to queue a message explicitly while it is
busy, use `:PiSend <text>` (handled per `g:pi_chat_streaming_behavior`).

Window switching is non-destructive: closing the chat window (or leaving it
and it being the last window on the buffer) just parks the agent — the
transcript and your half-typed prompt survive. Reopening with `:PiOpen` or
`:buffer __PiChat__` resumes the same conversation. `:PiClose` is the one that
actually tears the session down.

The panels also defend their own windows. If you run a buffer-switching
command (`:e file`, `:b`, `:bn`, …) while the cursor is on the chat or
thinking panel, the file is moved into your last real-file window and the
panel is restored in place, so a stray `:e` can never replace a panel. With
no file window open the file stays put and `:PiOpen` brings the panel back.

Sessions persist the usual way — pi stores them in `~/.pi/sessions` and
resumes by default; each `:PiOpen` continues the most recent session. Use
`g:pi_chat_no_session = 1` for `--no-session`.

### Working on an open file

The pi agent has read/write/bash tools but no idea which buffer you had on
screen, so the plugin tracks a **context file**: by default it's the buffer
you were viewing when `:PiOpen` started the session — if that was a bare
scratch buffer (plain `vim`), it falls back at send time to the buffer you
last had open (Vim's alternate buffer, `#`). Every prompt you send is
transparently prefixed with `The file I am working on is: <abs path>
(read it with your read tool; edit it in place when asked)` (shown
in the transcript as the bare `❯ text` you typed), and the pi job runs with
that file's directory as its working directory. Override it at any time with
`:PiFile <path>` (no argument prints the current one; changing it mid-session
applies to new prompts, the cwd change takes effect at the next `:PiOpen`).
Unsaved files work too: the path is passed with a `(not saved to disk yet;
create it when I ask for new content)` hint, so pi can create the file with
its write tool (as long as the parent directory exists). A still-unnamed scratch buffer gives no context file
(the job then runs in your shell's cwd). Disable with
`g:pi_chat_context_file = 0`.

When pi edits the context file (via its edit/write tool) the plugin reloads the
buffer from disk so you see the change live. If that buffer has unsaved changes
of your own, the reload is skipped with a notification and a `:e!` hint,
so it never clobbers your in-progress edits.

With `g:pi_chat_track_files` (default `1`) the context also follows your
working file automatically: opening a different real file (`:e`, `:b`, …)
re-keys it, and if the agent is running it is told the switch (logged in the
chat); with it parked, the new file is used on the next `:PiOpen`. Set
`g:pi_chat_track_files = 0` to keep the context fixed until you use `:PiFile`.

### Resuming a conversation

pi keeps its conversation history in its own session store. The plugin ties
each session to *your* context so `:PiOpen` picks up where you left off instead
of starting a fresh agent: a stable session id is derived from the context
file's path and passed to pi with `--session-id`, so reopening the same file
resumes that file's conversation. If you never chatted about that specific file
but did chat from its folder, `:PiOpen` falls back to the folder's conversation
(a file you just opened inherits its folder's history); otherwise a new
conversation is started. On resume the prior transcript is shown at the top of
the chat buffer, above the input line, so you have the context as you keep
working.

This is on by default. `g:pi_chat_no_session` still wins and forces a
disposable conversation. `g:pi_chat_session_resume = 0` passes no session id
at all, and pi then applies its own default (resume most recent session).
The config below turns it off or tunes the fallback and how much history is
shown.

## Configuration (`.vimrc`)

```vim
let g:pi_chat_split = 'vsplit'          " 'vsplit' (default) | 'split' | 'new'
let g:pi_chat_width = 60                " split width/height (float 0-1 = fraction of the window)
let g:pi_chat_args = []                 " extra pi args, e.g. ['--model', '...']
let g:pi_chat_no_session = 0            " 1 = pass --no-session
let g:pi_chat_streaming_behavior = 'followUp'  " 'followUp' (default) or 'steer'
let g:pi_chat_show_thinking = 0         " 1 = also render thinking deltas inline in the chat
let g:pi_chat_thinking_height = 0.3     " :PiThinking panel height: float 0-1 of the window, or lines
let g:pi_chat_markdown = 1              " 0 = disable the built-in markdown highlighting in the chat/thinking buffers
let g:pi_chat_map = '<leader>pi'        " '' disables the global mapping
let g:pi_chat_context_file = 1          " 1 = inject the context file into prompts
let g:pi_chat_track_files = 1           " 1 = re-key pi's context when you switch files (:e, :b, …)
let g:pi_chat_autosave_context = 0      " 1 = save the context file before each send (else prompt)
let g:pi_chat_run_timeout = 300         " 0 = off; N = warn if a run is still busy after N seconds
let g:pi_chat_session_resume = 1        " 1 = :PiOpen resumes the file's (or folder's) pi conversation
let g:pi_chat_session_fallback_dir = 1  " 1 = fall back to the file's folder session when no file session exists
let g:pi_chat_session_dir = ''          " '' = pi's default ~/.pi/agent/sessions; else an explicit store dir
let g:pi_chat_resume_max_messages = 50  " 0 = show the whole prior transcript; N = only the last N messages
```

`g:pi_chat_streaming_behavior` only matters when you send a prompt while the
agent is already running: `followUp` queues it until the run fully settles,
`steer` injects it after the current tool calls finish.

The chat and thinking panels render markdown with the plugin's own
buffer-local Vim highlighting (`g:pi_chat_markdown`, on by default):
headings, bold/italic, inline and fenced code, lists, quotes and links, all
layered on as the buffer streams in. Set `g:pi_chat_markdown = 0` to turn
it off.

`g:pi_chat_autosave_context` controls what happens when you send a prompt with
unsaved changes in the context file: `1` saves it to disk first (so pi edits
the file on disk); `0` (default) prompts you to save or cancel before sending.

`g:pi_chat_session_resume` (default `1`) makes `:PiOpen` resume the pi
conversation for the context file, falling back to its folder's conversation
(`g:pi_chat_session_fallback_dir`) when there is no file-level session, else
starting a new one. `g:pi_chat_resume_max_messages` caps how many prior messages
are shown on resume (`0` = the whole transcript, handy for a long-running file).
`g:pi_chat_no_session = 1` forces a disposable (unpersisted) conversation.

## Limitations

- Multi-line prompts are opened with `<C-CR>` only (there is no
  `<C-o><CR>`-style alias); if your terminal remaps `<C-CR>`, multi-line
  prompt input won't work.
- The transcript is plain text in a modifiable buffer.  If the chat window
  is focused, scrolling up while output streams leaves you in place; if
  focus is elsewhere, the window auto-follows the newest line so live
  updates stay visible without stealing focus.
- `bash_execution_update` progress and partial tool arguments are not
  rendered (tool status lines only).
- Extension `editor` requests open a temporary scratch buffer (`:w` saves,
  `:q!` cancels).

If the agent process dies (crash, an extension exiting, `:PiClose`), the
panel recovers: sending to a dead agent logs `⚠ agent process is not
running (use :PiOpen)` and clears the working state instead of wedging the
input, and `:PiOpen` restarts the agent (resuming the session for the same
file). `:PiClear` always forces a brand-new session.

## Development

Run the whole end-to-end suite (the basic E2E plus the scenarios in
`test/scenarios/`: `abort`, `abortreplay`, `abortresume`, `abortdeath`,
`clear`, `close`, `fail`, `markdown`, `model`, `multi`, `nosession`,
`notify`, `panelguard`, `pifile`, `pifilecmd`, `pisend`, `resume`, `think`,
`thinkoff`, `thinkpanel`, `tools`, `trackfile`, `working`) from the repo root.
The `abortreplay` scenario replays a captured real-pi session byte-for-byte
(`test/replay/`). The `stall` watchdog scenario is
manual-only (a slow fake triggers a headless hit-enter barrier):

```sh
sh test/run.sh            # all scenarios
sh test/run.sh think      # just one
```

Each scenario drives the real plugin through its public commands
(`:PiOpen`/`:PiFile`/`:PiClear`/`<CR>`-send) against `test/fake-pi.js` — a
deterministic stub `pi` RPC peer reached through the `test/pi` PATH shim — and
greps the transcript dump for the expected lines, asserting zero Vim E-errors.
Manual test with the real agent: `vim +PiOpen` (with `pi` on PATH).

Notes:

- `test/run.sh` exports `PATH=test:$PATH` so the plugin's
  `job_start(['pi', ...])` resolves the `test/pi` shim, which in turn finds
  `node` (it also falls back to `$HOME/.nvm/versions/node/*/bin`,
  `/opt/local/bin`, and `/usr/local/bin`).
- Each scenario is launched as `sleep N | vim --not-a-term -Nu ...`: the
  foreground `sleep` keeps vim's stdin open for N seconds (a closed stdin makes
  headless vim exit before its timers fire), and the pipeline always terminates
  at N seconds, so a run can never hang. `--not-a-term` is required on this vim
  build (it otherwise warns and can hang on a hit-enter prompt in non-TTY
  mode).
- `test/fake-pi.js` is env-configurable (`FAKE_PI_THINKING`, `FAKE_PI_TOOL`,
  `FAKE_PI_TOOLFAIL`, `FAKE_PI_TITLE`, `FAKE_PI_DELAY_MS`, `FAKE_PI_TURN_MS`,
  `FAKE_PI_EDIT_PATH`, …) so one stub covers every scenario; it also logs the
  lines it receives (`FAKE_PI_LOG`) and its launch argv (`FAKE_PI_ARGV_LOG`)
  for protocol assertions (e.g. the `model` scenario asserts the exact
  `set_model` line sent over stdin, and `nosession` asserts the `--no-session`
  startup arg).
- `g:pi_chat_run_timeout` watchdog: when a run is still busy past the budget the
  status line appends `(long run: :PiClose to stop)` and one transcript line
  `⏱ pi run exceeded Ns - may be stuck; :PiClose to force-stop` is logged.
  Verify by hand with a slow reply (or a hung pi).

Expected results (see `test/vimrc-test` header for the full spec):

- `PiChatStatusText()` samples: `pi chat` → `⠋ contacting pi 0s` (frames
  advance while the fake is slow to respond) → `⠋ pi is working …` (after
  `agent_start`) → `pi chat` (after `agent_settled`).
- `__PiChat__` buffer: header, `❯ hello fake`, the streamed `Echo: hello
  fake` reply, tool lines `⚙ bash …` / `✓ bash`, and the notify line.
- No `E*` errors in `/tmp/pilog.txt`.

Lint gates:

```sh
.venv/bin/vint plugin/pi_chat.vim   # pip install 'vim-vint==0.3.21' 'setuptools<81'
node --check test/fake-pi.js
```

Useful protocol reference: pi repo `docs/rpc.md` (commands, events,
extension UI protocol, example Python/Node clients).
