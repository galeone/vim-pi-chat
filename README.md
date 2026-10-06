# vim-pi-chat

A chat window for the [pi coding agent](https://github.com/earendil-works/pi)
inside Vim 9+ and Neovim 0.9+ (no GUI, no Node.js runtime needed by the
editor itself — it just speaks to the `pi` CLI).

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
(`job_start`/`ch_sendraw`). RPC mode is a strict JSON-lines protocol over
stdin/stdout (see pi's `docs/rpc.md`): commands go in as one JSON object per
line, events come back as one JSON object per line. The plugin:

- buffers stdout lines and drains them on a `timer_start` tick, so output
  never interrupts you mid-keystroke;
- renders `text_delta` deltas incrementally (line-buffered), tool executions
  as `⚙ …` / `✓ …` / `✗ …` lines, and your prompts as `❯ …`; `edit` and
  `write` tool calls additionally get a syntax-highlighted diff preview in
  the same format as pi's TUI (`g:pi_chat_tool_diff`), and other tools show
  the first lines of their output under the `✓` line (`│ …`,
  `g:pi_chat_tool_output`; a failed tool always shows its error output);
- answers extension UI requests: `notify` renders as an in-chat transcript
  line with a level marker (ℹ/⚠/⛔), and `confirm`/`select`/`input` use native
  Vim prompts showing the request's title and message. Esc always sends a
  cancellation (never a choice: Esc on "Allow dangerous command?" does not
  allow it), and an `input` placeholder is shown as a hint, not pre-filled.
  `setStatus` entries show in the chat statusline, `set_editor_text` prefills
  the `❯` prompt (once the turn ends, if pi is busy), and `setWidget` /
  `setTitle` are ignored. `editor` requests are answered as cancelled (see
  Limitations).

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
`plugin/pi_chat.vim` in your runtimepath; with a plugin manager add e.g.
`Plug 'galeone/vim-pi-chat'` as usual)

Requirements:

- Vim **9.0+** compiled with `+job +channel` (`vim --version | grep job`),
  or **Neovim 0.9+**
- the `pi` CLI installed and on `$PATH`
- `pi auth` done beforehand (the plugin never handles credentials)

## Usage

| Command | Effect |
| --- | --- |
| `:PiOpen` | open the chat **and** the thinking panel (chat in a vertical split on the right by default) |
| `:PiOpen <message>` | open (chat + thinking) and immediately send `<message>` |
| `:PiOpen quiet` | open (chat + thinking) without moving the cursor to the prompt (no focus steal, no insert mode) — used by the VimEnter boot hook so stray startup input can never be sent to the agent |
| `:PiSend <text>` | send a prompt to the running agent from any window (no text: jump to the chat prompt); while pi is busy it is queued per `g:pi_chat_streaming_behavior`. Anything half-typed on the `❯` prompt is kept and comes back when the turn ends. Errors if the agent is not running (use `:PiOpen` first) |
| `:PiAbort` | abort the current run (`{"type":"abort"}`) |
| `:PiClear` | start a fresh session: restarts the agent process (so extensions never see a replaced session) and **deletes the context's own saved session** from pi's store, reusing the same context-keyed session id. A folder conversation the file had only inherited is left untouched: the file gets its own fresh session |
| `:PiRestart` | re-launch the pi process in place, resuming the same session (transcript and context kept) |
| `:PiThinking` | toggle a small read-only panel across the bottom of the screen, under both your code and the chat (opened automatically with `:PiOpen`) streaming the model's thinking live, auto-scrolled to the newest line (height: `g:pi_chat_thinking_height`). Thoughts accumulate even while hidden, under a `──── prompt` marker per turn, so opening it later shows past thinking; `:PiClear` / `:PiClose` wipe it |
| `:PiClose` | stop the agent and close (tear down) the chat |
| `:PiFile [path]` | show or set the context file (see below) |
| `<leader>pi` | `:PiOpen` (default mapping, set `g:pi_chat_map` to change) |

In the chat buffer (buffer-local mappings): `A` (or `i`) jumps to the `❯` prompt and enters insert
mode, `<CR>` sends (multi-line: continuation lines are joined), and `<C-c>`
aborts the current run. While pi is generating a turn, typing on the prompt
is ignored (the prompt glyph is hidden and the input line is blanked — you
see an in-chat `⏳ pi is working…` line instead — and the statusline
spinner shows pi is working). The statusline also shows the current model
(pi reports it via `get_state` / `set_model` / `cycle_model`); model
changes are made from the pi side (e.g. pi's own `/model`), not from Vim. To queue a message explicitly while it is
busy, use `:PiSend <text>` (handled per `g:pi_chat_streaming_behavior`).

Window switching is non-destructive: closing the chat window (or leaving it
and it being the last window on the buffer) just parks the agent — the
transcript and your half-typed prompt survive. Reopening with `:PiOpen` or
`:buffer __PiChat__` resumes the same conversation. `:PiClose` is the one that
actually tears the session down.

Quitting your last file window takes the panels with it: `:q`, `:x`, `:wq`
or `ZZ` in the last real window of a tab also closes the pi panels there, so
the command exits Vim (or closes the tab) as it would without the plugin — no
`:qall` needed. With another file window still open, or when you quit from
inside the chat (which parks the agent), nothing extra happens; `:close` and
`:only` are never affected. If the quit then fails (e.g. `E37` unsaved
changes on `:q`), the panels stay closed and `:PiOpen` brings them back.
Set `g:pi_chat_quit_with_last_window = 0` for plain Vim behavior.

The panels also defend their own windows. If you run a buffer-switching
command (`:e file`, `:b`, `:bn`, …) while the cursor is on the chat or
thinking panel, the file is moved into your last real-file window and the
panel is restored in place, so a stray `:e` can never replace a panel. With
no file window open the file stays put and `:PiOpen` brings the panel back.

Sessions persist the usual way — pi stores them in
`~/.pi/agent/sessions` and `:PiOpen` resumes the conversation for the
context file (see Resuming a conversation). Use `g:pi_chat_no_session = 1`
for `--no-session`.

### Working on an open file

The pi agent has read/write/bash tools but no idea which buffer you had on
screen, so the plugin tracks a **context file**: by default it's the buffer
you were viewing when `:PiOpen` started the session — if that was a bare
scratch buffer (plain `vim`), it falls back at send time to the buffer you
last had open (Vim's alternate buffer, `#`). Every prompt you send is
transparently prefixed with `The file I am working on is: <abs path>
(read it if you need its contents; edit it in place when asked)` (shown
in the transcript as the bare `❯ text` you typed), and the pi job runs with
that file's directory as its working directory. Override it at any time with
`:PiFile <path>` (no argument prints the current one; changing it mid-session
applies to new prompts, while the job's cwd only changes the next time the pi
process starts: `:PiRestart`, `:PiClear`, or reopening a parked chat).
Unsaved files work too: the path is passed with a `(not saved to disk yet;
create it when I ask for new content)` hint, so pi can create the file with
its write tool (as long as the parent directory exists). A still-unnamed scratch buffer gives no context file
(the job then runs in your shell's cwd). Disable with
`g:pi_chat_context_file = 0`.

When pi edits the context file the plugin reloads the buffer from disk so
you see the change live — immediately, even if that window is in the
background (the plugin forces a full redraw after reloading, since vim may
otherwise not repaint a non-current window until your next keystroke). This
covers the edit/write tools, and — because the plugin snapshots the file's
`[mtime, size]` around every tool call — *any* tool that rewrites the file
(a `bash` one-liner included), logged as `ℹ reloaded TODO (changed on disk)`.
Tool calls that pi runs in parallel are tracked individually, so every file
they touch is reloaded. The reload goes through Vim's own file-change check
(`:checktime` with `'autoread'` on for that buffer), so it keeps your cursor
and undo history and Vim records the new timestamp: no "file changed" warning
follows on `:w` or focus.
If the buffer has unsaved changes of your own, the reload is skipped with a
notification and a `:e!` hint, so it never clobbers your in-progress edits.

Edits that don't go through pi at all (your own shell in another terminal,
git, another process) are vim's territory: `'autoread'` re-reads an
unmodified buffer when vim notices the file changed, and never touches a
buffer with unsaved changes. In a terminal vim only notices on certain
events, so give it one:

```vim
set autoread
set updatetime=200
augroup AutoRead
  autocmd!
  autocmd CursorHold,CursorHoldI * checktime
  autocmd FocusGained * checktime   " needs focus events (tmux: set -g focus-events on)
augroup END
```

An unmodified buffer then refreshes within ~200ms of any external write; a
modified one is left alone until you `:e!`. (The tempting `clientserver`
remote-poke alternative is not available in the current MacPorts 9.2 build:
it advertises `+clientserver` but lacks the `servername` option, like other
shaved APIs in that build.)

With `g:pi_chat_track_files` (default `1`) the context also follows your
working file automatically: opening a different real file (`:e`, `:b`, …)
re-keys it (logged in the chat while the agent runs). pi is not sent a prompt
of its own for the switch, so jumping around files (`:e`, `:b`, quickfix)
costs no model turns: your next prompt tells it, opening with `I switched the
file I am working on to: <path>` instead of the usual context line. With the
agent parked, the new file is simply used on the next `:PiOpen`. Set
`g:pi_chat_track_files = 0` to keep the context fixed until you use `:PiFile`.

### Resuming a conversation

pi keeps its conversation history in its own session store. The plugin ties
each session to *your* context so `:PiOpen` picks up where you left off instead
of starting a fresh agent: a stable session id (`pchat-<len>-<sha256 of the
resolved path>`) is derived from the context file's path and passed to pi with
`--session-id`, so reopening the same file
resumes that file's conversation. If you never chatted about that specific file
but did chat from its folder, `:PiOpen` falls back to the folder's conversation
(a file you just opened inherits its folder's history); otherwise a new
conversation is started. On resume the prior transcript is shown at the top of
the chat buffer, above the input line, so you have the context as you keep
working. It is laid out like the live chat: your prompts appear as you typed
them (without the context line the plugin adds for pi), and only the
session's current branch is shown (pi keeps abandoned branches in the same
file).

This is on by default. `g:pi_chat_no_session` still wins and forces a
disposable conversation. `g:pi_chat_session_resume = 0` passes no session id
at all, and pi then applies its own default (a new session each time).
The config below turns it off or tunes the fallback and how much history is
shown.

### Opening the chat at startup (without stealing focus)

If you want the panel already open when vim starts, hook `:PiOpen` into
`VimEnter`. The safe form is a small boot function:

```vim
" Open the chat panel at startup, without stealing focus.
function! s:pi_boot() abort
  if exists(':PiOpen') && !&diff && (has('terminal') || has('gui_running'))
    let s:pi_boot_win = win_getid()
    PiOpen quiet
    call win_gotoid(s:pi_boot_win)
    unlet s:pi_boot_win
  endif
endfunction
autocmd VimEnter * call s:pi_boot()
```

There are two reasons for the exact shape:

1. **Focus.** A plain `:PiOpen` leaves the cursor in the chat's insert-mode
   prompt, so your first keystroke after startup would be typed into the
   prompt (and `<CR>` there sends it to pi). `:PiOpen quiet` starts the job
   and opens the split but skips the insert-mode focus, and `win_gotoid()`
   returns the cursor to the window you were in. Both parts matter: the chat
   window still gains focus the moment the split opens (the window manager
   does that), and pi's first streamed output re-focuses it — so
   `win_gotoid` alone is not enough; it is the quiet flag that keeps your
   keystrokes out of the prompt.

2. **Keep `:PiOpen` alone on its line.** The command is `-nargs=*`, and at
   least one stripped-down vim build parses the rest of a `|`-chained logical
   line as part of its argument: `... | PiOpen quiet | win_gotoid(w)` made
   `:PiOpen` receive the whole string `quiet | win_gotoid(w)` and send it to
   pi as a user message — a stray boot send. Wrapping the call in a function
   so `PiOpen quiet` sits alone on its line sidesteps that completely.

## Configuration (`.vimrc`)

```vim
let g:pi_chat_split = 'vsplit'          " 'vsplit' (default) | 'split' | 'new' (both horizontal)
let g:pi_chat_width = 60                " split width/height (float 0-1 = fraction of the screen)
let g:pi_chat_args = []                 " extra pi args, e.g. ['--model', '...']
let g:pi_chat_no_session = 0            " 1 = pass --no-session
let g:pi_chat_streaming_behavior = 'followUp'  " 'followUp' (default) or 'steer'
let g:pi_chat_show_thinking = 0         " 1 = also render thinking deltas inline in the chat
let g:pi_chat_thinking_height = 0.3     " :PiThinking panel height: float 0-1 of the screen height, or rows
let g:pi_chat_markdown = 1              " 0 = disable the built-in markdown highlighting in the chat/thinking buffers
let g:pi_chat_map = '<leader>pi'        " '' disables the global mapping
let g:pi_chat_context_file = 1          " 1 = inject the context file into prompts
let g:pi_chat_track_files = 1           " 1 = re-key pi's context when you switch files (:e, :b, …)
let g:pi_chat_quit_with_last_window = 1 " 1 = :q/:x in the last file window also closes the pi panels (exits Vim)
let g:pi_chat_master_prompt = ''        " file path (or inline text) of standing rules, appended to pi's system prompt
let g:pi_chat_autosave_context = 0      " 1 = save the context file before each send (else prompt)
let g:pi_chat_tool_diff = 1             " 1 = show a diff preview for pi's edit/write tool calls
let g:pi_chat_tool_diff_max = 200       " cap diff previews at N lines (0 = unlimited)
let g:pi_chat_tool_output = 5           " show N lines of tool output under ✓/✗ (0 = off)
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

`g:pi_chat_master_prompt` sets standing rules for the whole conversation: a
file path (e.g. `"~/.pi-master-prompt.md"`) or a plain string of instructions
is passed to pi with `--append-system-prompt`, so the rules are in the system
prompt from the first message of every session (fresh and resumed). A
readable file is sent as an absolute path and pi loads its contents; anything
else is treated as inline text. The chat log shows which one was applied when
a fresh session starts. Changes take effect when the pi job restarts (e.g.
`:PiClear`, or `:PiClose` + `:PiOpen`).

`g:pi_chat_autosave_context` controls what happens when you send a prompt with
unsaved changes in the context file: `1` saves it to disk first (so pi edits
the file on disk); `0` (default) prompts you first — save the changes, or
let pi edit the on-disk version.

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
- Tool progress (`tool_execution_update`) and partial tool arguments are not
  rendered: a tool's output appears once it finishes.
- Extension `editor` requests (multi-line text dialogs) are not supported
  yet: they are answered as cancelled right away, with a ⚠ notice in the chat.
- Dialog `timeout`s are not enforced on the Vim side (Vim runs no timers while
  a prompt is waiting); pi resolves a timed-out dialog itself.

If the agent process dies (crash, an extension exiting, `:PiClose`), the
panel recovers: sending to a dead agent logs `⚠ agent process is not
running (use :PiOpen)` and clears the working state instead of wedging the
input, and `:PiOpen` restarts the agent (resuming the session for the same
file). `:PiClear` always forces a brand-new session.

## Development

Run the whole end-to-end suite (the basic E2E plus the scenarios in
`test/scenarios/`: `abort`, `abortreplay`, `abortresume`, `abortdeath`,
`blankgap`, `clear`, `cleardir`, `clearwipe`, `close`, `closethink`, `crash`,
`cursorprompt`, `dialogs`, `fail`, `leak`, `markdown`, `modelstatus`, `multi`,
`nldelta`, `nosession`, `notify`, `notifycursor`, `panelguard`,
`paralleltools`, `park`, `pifile`, `pifilecmd`, `pisend`, `queue`, `quitkeep`, `quitoff`, `quitx`,
`reject`,
`reload`, `restart`, `resume`, `resumefmt`, `resumethink`, `sessionid`,
`stash`, `think`, `thinkoff`, `toolout`, `tooloutfail`,
`thinkpanel`, `tools`, `trackfile`, `working`, `diffedit`, `diffoff`,
`diffwrite`, `diskchg`) from the repo root.
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
  `FAKE_PI_EDIT_PATH`, `FAKE_PI_DELTAS`, `FAKE_PI_REJECT`, `FAKE_PI_CRASH_MS`,
  `FAKE_PI_QUEUE`, `FAKE_PI_LIFE_LOG`, `FAKE_PI_PARALLEL`, `FAKE_PI_TOOL_OUTPUT`,
  …; see its header) so one stub covers
  every scenario; it also logs the
  lines it receives (`FAKE_PI_LOG`) and its launch argv (`FAKE_PI_ARGV_LOG`)
  for protocol assertions (e.g. `nosession` asserts the `--no-session`
  startup arg, `clear` asserts the `--session-id` kept across the restart).
- `g:pi_chat_run_timeout` watchdog: when a run is still busy past the budget the
  status line appends `(long run: :PiClose to stop)` and one transcript line
  `⏱ pi run exceeded Ns - may be stuck; :PiClose to force-stop` is logged.

### Releasing

Releases are automated with [semantic-release](https://github.com/semantic-release/semantic-release):
a `release` job (`.github/workflows/test.yml`, config in `release.config.json`)
runs after the E2E suite passes on pushes to `main`, bumps the version from the
conventional commit messages, tags it (`vX.Y.Z`) and publishes a GitHub Release
with generated notes. To trigger a release, write commits as `fix: …` (patch),
`feat: …` (minor) or with a `BREAKING CHANGE` footer / `!` suffix (major);
plain messages do not produce a release.
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
