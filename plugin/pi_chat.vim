" vim: set ft=vim ts=2 sw=2 sts=2 et:
scriptencoding utf-8
let s:save_cpo = &cpo
set cpo&vim
" ---------------------------------------------------------------------------
" pi_chat.vim — a pi coding-agent chat inside classic Vim
"
" Spawns `pi --mode rpc` (JSON lines over stdin/stdout) as a background job
" and renders the conversation in a dedicated split buffer:
"
"   :PiOpen              open the chat window (vertical split on the right)
"                        and the thinking panel
"   :PiOpen fix the bug  open and immediately send a prompt
"   :PiOpen quiet        open without moving the cursor (VimEnter boot hook)
"   :PiSend <text>       send a prompt from the command line (the agent must
"                        be running; no text = jump to the prompt)
"   :PiAbort             abort the current agent run
"   :PiClear             start a fresh session (restarts the pi process)
"   :PiRestart           restart the pi process, resuming the same session
"   :PiClose             close the chat and stop the agent
"   :PiThinking          toggle a full-width panel at the bottom streaming the model's
"                        thinking live (g:pi_chat_thinking_height)
"   :PiFile [path]       show/set the context file (default: the buffer you had
"                        open when :PiOpen started the session; pi's job runs
"                        in its directory and prompts mention it)
"
" Typing happens directly on the ❯ prompt line; everything above it is
" the read-only transcript (locked against accidental edits):
"   <CR>      send the message (multi-line: type several lines, then <CR>)
"   <C-CR>    insert a line break in the message
"   <C-c>     abort the running agent
"   <Esc>     back to normal mode (A / i in the chat jump back to the prompt)
"   while pi is generating a turn, typing on the prompt is ignored (each
"   keystroke is reverted); :PiSend still sends/queues explicitly
"
" Closing the chat window parks the agent (buffer + transcript are kept);
" :PiOpen or :b __PiChat__ resumes the same session.
"
" Requirements:
"   - Vim 9.0+ compiled with +job and +channel (Neovim is not supported:
"     the plugin uses Vim's job/channel API)
"   - the `pi` CLI on $PATH (pi auth must already be done)
"
" Configuration (set in .vimrc before the plugin loads; see :help pi_chat):
"   g:pi_chat_split                'vsplit' (default), 'split', or 'new'
"                                  (both 'split' and 'new' are horizontal)
"   g:pi_chat_width                split width/height: integer columns/rows
"                                  (default 60) or float 0-1 for a fraction
"                                  of the screen (0.4 = 40%)
"   g:pi_chat_thinking_height      :PiThinking panel height (default 0.3):
"                                  integer rows or float 0-1 fraction of the
"                                  screen height
"   g:pi_chat_args                 extra pi args, e.g. ['--model', '...']
"   g:pi_chat_no_session           1 = pass --no-session (no persistence)
"   g:pi_chat_streaming_behavior   'followUp' (default) or 'steer'
"   g:pi_chat_show_thinking        1 = also render thinking deltas in the chat
"   g:pi_chat_markdown             0 = no markdown highlighting (default 1)
"   g:pi_chat_map                  global normal-mode mapping, default <leader>pi
"   g:pi_chat_context_file         1 = inject the context file into prompts
"   g:pi_chat_track_files          1 = tell pi when you switch files (:e, :b)
"   g:pi_chat_quit_with_last_window 1 = :q/:x in the last file window also
"                                  closes the pi panels (exits Vim)
"   g:pi_chat_autosave_context     1 = save the context file before a send
"                                  (default 0: ask first)
"   g:pi_chat_tool_diff            1 = diff preview for edit/write tools
"   g:pi_chat_tool_diff_max        cap diff previews at N lines (0 = no cap)
"   g:pi_chat_tool_output          show N lines of tool output (default 5, 0 = off)
"   g:pi_chat_run_timeout          warn when a run exceeds N seconds (0 = off)
"   g:pi_chat_master_prompt        path to a markdown file (or inline text) with
"                                  standing rules, appended to pi's system prompt
"                                  when the session starts (~ and relative paths
"                                  are expanded from vim's cwd)
"   g:pi_chat_session_resume       1 = resume the file's (or folder's) session
"   g:pi_chat_session_fallback_dir 1 = fall back to the folder's session
"   g:pi_chat_session_dir          pi session store ('' = ~/.pi/agent/sessions)
"   g:pi_chat_resume_max_messages  prior messages shown on resume (0 = all)
"
" Protocol reference: pi docs/rpc.md
" ---------------------------------------------------------------------------

if exists('g:loaded_pi_chat')
  finish
endif
" Vim 9.0+ or Neovim 0.9+. The job/channel layer is abstracted by
" autoload/pi_chat_compat.vim so both editors work from the same code.
if has('nvim')
  if !has('nvim-0.9')
    echohl WarningMsg
    echomsg 'pi-chat: requires Neovim 0.9+'
    echohl None
    finish
  endif
else
  if !has('job') || !has('channel')
    echohl WarningMsg
    echomsg 'pi-chat: requires Vim compiled with +job and +channel'
    echohl None
    finish
  endif
  if v:version < 900
    echohl WarningMsg
    echomsg 'pi-chat: requires Vim 9.0+'
    echohl None
    finish
  endif
endif

let g:loaded_pi_chat = 1

" Ensure the plugin root is on &rtp so autoload/pi_chat_compat.vim is found
" even when the plugin is loaded via a raw :source (e.g. the test harness).
execute 'set rtp^=' . fnameescape(fnamemodify(resolve(expand('<sfile>:p')), ':h:h'))

" ----------------------------- configuration -------------------------------

if !exists('g:pi_chat_split')                | let g:pi_chat_split = 'vsplit' | endif
if !exists('g:pi_chat_thinking_height')      | let g:pi_chat_thinking_height = 0.3 | endif
if !exists('g:pi_chat_width')                | let g:pi_chat_width = 60 | endif
if !exists('g:pi_chat_args')                 | let g:pi_chat_args = [] | endif
if !exists('g:pi_chat_no_session')           | let g:pi_chat_no_session = 0 | endif
if !exists('g:pi_chat_streaming_behavior')   | let g:pi_chat_streaming_behavior = 'followUp' | endif
if !exists('g:pi_chat_show_thinking')        | let g:pi_chat_show_thinking = 0 | endif
if !exists('g:pi_chat_map')                  | let g:pi_chat_map = '<leader>pi' | endif
if !exists('g:pi_chat_context_file')         | let g:pi_chat_context_file = 1 | endif
if !exists('g:pi_chat_track_files')          | let g:pi_chat_track_files = 1 | endif
" :q / :x / :wq / ZZ in the last real window of a tab also closes the pi
" panels there, so the command exits Vim (or closes the tab) instead of
" leaving you in the chat.
if !exists('g:pi_chat_quit_with_last_window') | let g:pi_chat_quit_with_last_window = 1 | endif
if !exists('g:pi_chat_autosave_context')     | let g:pi_chat_autosave_context = 0 | endif
" Show a pi-style diff preview for file tools (write/edit).  1 = on,
" 0 = off (just the "✓ write"/"✓ edit" line).
if !exists('g:pi_chat_tool_diff')           | let g:pi_chat_tool_diff = 1 | endif
" Cap diff previews at this many lines; 0 = no cap.
if !exists('g:pi_chat_tool_diff_max')       | let g:pi_chat_tool_diff_max = 200 | endif
" Show up to this many lines of a tool's output under its ✓/✗ line (0 = off).
" Successful read/edit/write are skipped (file contents, or the diff above).
if !exists('g:pi_chat_tool_output')         | let g:pi_chat_tool_output = 5 | endif
" Master prompt: a file (or inline text) of standing rules, passed to pi with
" --append-system-prompt so every session starts with it in the system prompt.
if !exists('g:pi_chat_master_prompt')        | let g:pi_chat_master_prompt = '' | endif
" Auto-resume a pi session keyed to the file you opened (then its folder):
" the file/folder -> session association is implicit, via a stable id derived
" from the path and passed to pi with --session-id (create-or-resume).
if !exists('g:pi_chat_session_resume')       | let g:pi_chat_session_resume = 1 | endif
if !exists('g:pi_chat_session_fallback_dir') | let g:pi_chat_session_fallback_dir = 1 | endif
if !exists('g:pi_chat_session_dir')          | let g:pi_chat_session_dir = '' | endif
" Cap the resumed transcript to the most recent N messages (0 = no cap): a
" long pi session can have thousands of messages, and loading them all into
" the chat buffer on open would be slow and overwhelming.
if !exists('g:pi_chat_resume_max_messages')  | let g:pi_chat_resume_max_messages = 50 | endif
" Warn when a single run is still in flight after this many seconds (0 = off):
" a hung pi (alive but unresponsive) otherwise spins forever with no signal.
if !exists('g:pi_chat_run_timeout')          | let g:pi_chat_run_timeout = 300 | endif

" ------------------------------ internal state -----------------------------

" The pi process: a Job, or v:null when none is tracked.  Test it with
" s:HasJob(), never empty(): empty() is also true for a Job that has exited.
let s:job = v:null
let s:buf = -1
let s:bufname = '__PiChat__'
" File the user was working on when :PiOpen started the session. Injected into
" prompts so the agent knows which document to read/edit (and used as the pi
" job's cwd).
let s:context_file = ''
let s:context_buf = -1
" window bookkeeping for s:PanelGuard(): winid of the last window showing a
" real file, and winid -> panel bufnr for windows currently showing one.
let s:file_win = 0
let s:panel_wins = {}
" The pi session id in use for the current job ('' = none / pi default), and
" the resume kind chosen at start ('file', 'dir' or 'new') for the log hint.
let s:session_id = ''
let s:resumed_kind = ''
" 1 after g:pi_chat_track_files re-keyed the context file: the next prompt
" tells pi about the switch (see s:FileSwitch / s:UserPrompt).
let s:switch_pending = 0
" 1 while s:StartJob() is opening the chat window (see s:ChatWinGained).
let s:starting = 0
" Pending deferred park check (timer id, or -1); see s:ChatWinLost.
let s:park_timer = -1
" Transcript protection (this Vim build has no :textlock). We keep an
" authoritative copy of the log in s:transcript and, on any user edit, detect a
" mismatch and restore it.
let s:transcript = []
let s:guarding = 0
let s:pinning = 0
" Half-typed prompt block saved while a :PiSend prompt runs (restored by
" s:HideWorking when the turn ends), or text pi asked to prefill
" (set_editor_text) while busy.
let s:input_stash = []
" Extension status entries (setStatus): statusKey -> statusText.
let s:ext_status = {}
" Reentrancy flag for s:GuardBusyInput (typing while pi is generating).
let s:typing_guard = 0
" Thinking panel (:PiThinking): a small horizontal split under the chat
" buffer where the model's thinking streams live. -1 = never created.
let s:think_buf = -1       " bufnr of the thinking panel buffer, or -1
let s:think_text = ''      " full thinking text for the current turn
" Incremental panel sync state: streamed deltas are collected in
" s:think_pending (O(1) per delta) and the panel buffer is brought up to
" date ONCE per drain tick (s:ThinkFlush) instead of per delta, which made
" long thinking sessions O(n^2).  s:think_frag is the trailing in-flight
" line of s:think_synced_text ('' while it ends in a newline or is empty),
" s:think_synced_text the prefix of s:think_text already reflected in the
" buffer, s:think_lines the buffer's line count, s:think_synced whether
" the buffer matches that rendered state (0 when the panel is closed or a
" full re-render is due).
let s:think_frag = ''
let s:think_lines = 0
let s:think_synced = 0
let s:think_pending = []
let s:think_synced_text = ''
let s:think_dirty = 0
" Model label for the statusline (filled from pi's get_state / set_model /
" cycle_model responses, i.e. only after pi confirmed). Empty until pi answers.
let s:model_label = ''
" Buffers already given buffer-local markdown highlighting (avoid dupes).
let s:md_done = {}
" Buffer invariants:
"   lines 1 .. len(s:transcript) are the read-only log and must always match
"   s:transcript byte-for-byte. The input block occupies every line from
"   s:input_line (= len(s:transcript) + 1) to the end; its first line is the
"   prompt and may span several lines (opened with <C-CR>).
"   s:tail_line (0 = inactive) is the log line holding the in-progress
"   streaming fragment (s:tail); it sits directly above the input block.
let s:input_line = 0
let s:tail_line = 0
let s:tail = ''
" changedtick of the last programmatic edit the plugin made to the chat
" buffer (kept current by the s:SetLine/s:AppendLines/s:DeleteLines
" primitives).  s:GuardTranscript uses it to tell plugin-driven TextChanged
" events (bail out in O(1)) apart from real user edits (full compare).
let s:plugin_tick = 0

" In-flight tool calls, keyed by pi's toolCallId (tool calls from one
" assistant message can run in parallel, so a single "current tool" would be
" overwritten by the next start).  Each entry holds:
"   path  the file the tool targets (tool_execution_start args), so
"         tool_execution_end can live-reload the open buffer if pi edited a
"         file the user has loaded;
"   stat  [mtime, size] of the context file at the tool's start.  If either
"         differs at its end and the tool was not edit/write (those already
"         reload), *something* (e.g. a bash sed) rewrote the file, so the
"         open buffer is reloaded the same way.  Size disambiguates edits
"         landing in the same wall-clock second (getftime is second-granular).
let s:tools = {}

let s:running = 0
let s:queue = []
let s:drain_timer = ''
let s:req_id = 0
let s:pending_msg = ''
" 1 = the :PiOpen that started this job passed the `quiet` flag: open the
" chat split but do NOT move the cursor to the prompt in insert mode
" (used by the VimEnter boot hook so stray input at startup can never be
" silently sent to the agent as a message).
let s:quiet = 0
" 1 = about to create a brand-new session, 0 = resuming a parked one.
let s:fresh = 1
" Set by :PiClear: the next s:StartJob must launch a brand-new session even
" though the context already maps to an existing (pre-clear) session file.
let s:clear_new_session = 0

" Busy indicator: an animated spinner in the chat buffer's statusline runs
" from the moment a prompt is sent until the turn settles, so the user can
" tell the message was received and the model has been contacted.
let s:busy = 0
let s:busy_since = ''
let s:spin = 0
let s:run_timeout_fired = 0
let s:spin_frames =
      \ ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

" ------------------------------- public API --------------------------------

function! s:PiOpen(...)
  " :PiOpen quiet — open (or reveal) the chat without stealing focus: no
  " window jump, no insert mode on the prompt.
  let l:quiet = (a:0 > 0 && a:1 ==# 'quiet')
  let s:quiet = l:quiet
  if a:0 > 0 && !l:quiet
    let s:pending_msg = a:1
    let l:len = strlen(s:pending_msg)
    let l:dq = nr2char(34)
    let l:sq = nr2char(39)
    if l:len >= 2 && ((s:pending_msg[0] ==# l:dq && s:pending_msg[l:len - 1] ==# l:dq)
          \ || (s:pending_msg[0] ==# l:sq && s:pending_msg[l:len - 1] ==# l:sq))
      let s:pending_msg = strpart(s:pending_msg, 1, l:len - 2)
    endif
  endif

  if s:JobAlive() && s:buf > 0 && buflisted(s:buf)
    if l:quiet
      " Stay put: only make sure the thinking panel is not left hidden.
      call s:PiShowThinking()
      return
    endif
    call s:JumpToBuf()
    if !empty(s:pending_msg)
      let l:m = s:pending_msg
      let s:pending_msg = ''
      call s:UserPrompt(l:m)
    endif
    call s:PiShowThinking()
    return
  endif

  " A parked (window-closed) session: the transcript is still there, so just
  " restart the agent in the same context.
  if s:buf > 0 && buflisted(s:buf)
    echo 'pi chat: resuming parked session'
    let s:fresh = 0
    call s:StartJob()
    if !empty(s:pending_msg)
      let l:m = s:pending_msg
      let s:pending_msg = ''
      call s:UserPrompt(l:m)
    endif
    call s:PiShowThinking()
    return
  endif

  " Fresh session: capture the buffer the user was viewing before the chat
  " window took over.
  let s:context_file = expand('%:p')
  " Only pin a buffer number when the context is actually a named file
  " buffer: an unnamed buffer can later be named by :e file, and virtual
  " buffers are never context files.
  let s:context_buf = (empty(bufname('%'))
        \ || !empty(getbufvar('%', '&buftype')) ? -1 : bufnr('%'))
  let s:fresh = 1
  call s:StartJob()

  if !empty(s:pending_msg)
    let l:m = s:pending_msg
    let s:pending_msg = ''
    call s:UserPrompt(l:m)
  endif
  call s:PiShowThinking()
endfunction

function! s:PiSend(...)
  if !s:JobAlive()
    echohl ErrorMsg
    echomsg 'pi-chat: agent is not running (use :PiOpen first)'
    echohl None
    return
  endif
  if a:0 == 0
    call s:JumpToBuf()
    call s:GotoInputInsert()
    return
  endif
  let l:text = a:1
  " :PiSend takes the argument as typed (<q-args>); if the user quoted the
  " whole argument, drop the outer quotes.
  let l:len = strlen(l:text)
  let l:dq = nr2char(34)
  let l:sq = nr2char(39)
  if l:len >= 2 && ((l:text[0] ==# l:dq && l:text[l:len - 1] ==# l:dq)
        \ || (l:text[0] ==# l:sq && l:text[l:len - 1] ==# l:sq))
    let l:text = strpart(l:text, 1, l:len - 2)
  endif
  call s:UserPrompt(l:text)
endfunction

" Window id of a window showing the chat buffer (any tab), or -1.
function! s:FindWin()
  return s:buf > 0 ? get(win_findbuf(s:buf), 0, -1) : -1
endfunction

" Run a closure with the chat window guaranteed current.  The chat pipeline
" (s:AddLogLines/s:FlushTail/s:CaptureTranscript/s:CommitTail/s:SpinnerUpdate)
" addresses the CURRENT window by line number (append/setline/getline), so it
" must run with chat current.  But the 50ms drain timer and the job-exit
" callback fire whenever the event loop turns, even while the user is in the
" thinking panel or another window - without this, those ops would write to
" the wrong buffer and s:CaptureTranscript would copy the *panel's* text into
" s:transcript, which the next s:GuardTranscript then dumps into the chat.
"
" A pure focus hop fires no BufWinEnter/BufWinLeave (the buffer stays on
" display in its window) and Vim defers the redraw until the closure returns,
" so the hop is invisible and the park/resume logic is untouched.  On the way
" out we park the chat cursor on the prompt line so an unfocused chat
" auto-follows its newest content, then restore the user's window.
function! s:WithChatWin(fn)
  let l:win = s:FindWin()
  if l:win < 1 || win_getid() == l:win
    " Chat absent or already current: run in place.
    return a:fn()
  endif
  let l:here = win_getid()
  " noautocmd: win_gotoid fires BufLeave/WinEnter/BufEnter, so without it
  " every hop runs the user's (and our own) Buf/WinEnter autocmds twice.
  try
    noautocmd call win_gotoid(l:win)
  catch
    " Chat window vanished mid-tick; degrade to running in the current window.
    return a:fn()
  endtry
  try
    let l:r = a:fn()
  finally
    if win_getid() == l:win && s:buf > 0 && s:input_line > 0
      let l:n = min([s:input_line, line('$')])
      call cursor(l:n, s:InputCol(l:n))
    endif
    try
      noautocmd call win_gotoid(l:here)
    catch
    endtry
  endtry
  return l:r
endfunction

function! s:GotoInput()
  call s:SyncInputLine()
  if s:buf > 0 && buflisted(s:buf) && s:input_line > 0
    let l:win = s:FindWin()
    if l:win > 0
      call win_gotoid(l:win)
      if s:input_line > line('$')
        let s:input_line = line('$')
      endif
      call cursor(s:input_line, s:InputCol(s:input_line))
    endif
  endif
endfunction

" Insert column on the prompt line: just after the ❯ prefix, or 1.
" col()/cursor() are BYTE columns and '❯' is 3 bytes, so the '❯ ' prefix spans
" bytes 1-4 and the first editable position is byte 5.  (Returning 3 would land
" the cursor on the ❯ itself, letting the user type in front of it in the
" default/white colour instead of the blue prompt colour.)
function! s:InputCol(lnum)
  if a:lnum == s:input_line
    let l:line = getline(s:input_line)
    if strcharpart(l:line, 0, 2) ==# '❯ '
      return strlen('❯ ') + 1
    endif
    if strcharpart(l:line, 0, 1) ==# '❯'
      return strlen('❯') + 1
    endif
  endif
  return 1
endfunction

function! s:GotoInputInsert()
  call s:GotoInput()
  startinsert!
endfunction

" Recover the prompt line after any user edit: it is the first line past the
" authoritative transcript.
function! s:SyncInputLine()
  if s:buf > 0 && buflisted(s:buf)
    let s:input_line = len(s:transcript) + 1
    if s:input_line < 1
      let s:input_line = 1
    endif
  endif
endfunction

" Chat-buffer primitives.  Everything that edits the transcript goes through
" these, which address the chat BUFFER (s:buf) rather than the current
" window: :PiSend, :PiFile, :PiAbort, the drain tick, ... can all run while
" the user sits in a file window or while the chat is hidden (parked), and
" the window-relative getline()/setline()/append()/line('$') then read and
" rewrote the user's FILE (a :PiSend from a file window deleted its lines
" and wrote the transcript into it).
function! s:NLines()
  return getbufinfo(s:buf)[0].linecount
endfunction

function! s:Line(lnum)
  return get(getbufline(s:buf, a:lnum), 0, '')
endfunction

" The chat buffer's programmatic edits go through these three primitives so
" s:plugin_tick (the buffer's changedtick after the last plugin edit) stays
" accurate.  s:GuardTranscript bails out in O(1) when the newest edit was
" the plugin's own; s:transcript is kept incrementally by the call sites
" (O(1) per delta) instead of a full getbufline per delta - the old
" per-delta capture plus per-keystroke compare is what made long sessions
" crawl at O(n^2).
function! s:SetLine(lnum, text)
  call setbufline(s:buf, a:lnum, a:text)
  let s:plugin_tick = getbufvar(s:buf, 'changedtick')
endfunction

function! s:AppendLines(after, lines)
  call appendbufline(s:buf, a:after, a:lines)
  let s:plugin_tick = getbufvar(s:buf, 'changedtick')
endfunction

function! s:DeleteLines(first, last)
  if a:last >= a:first
    call deletebufline(s:buf, a:first, a:last)
    let s:plugin_tick = getbufvar(s:buf, 'changedtick')
  endif
endfunction

" Refresh the authoritative transcript copy from the buffer's log region
" (lines 1 .. s:input_line-1).  The hot streaming paths keep s:transcript
" incrementally (O(1) per delta); this full re-capture remains for the rare
" non-streaming paths (turn end, user commands, restore, new session).
function! s:CaptureTranscript()
  let l:stop = s:input_line - 1
  if l:stop < 1 || s:buf < 1 || !bufloaded(s:buf)
    let s:transcript = []
  else
    let s:transcript = getbufline(s:buf, 1, l:stop)
  endif
endfunction

" Revert any user edit to the read-only log. Every plugin edit re-captures
" s:transcript right away (s:CaptureTranscript), so when TextChanged fires
" and the log region no longer matches it, the user typed into the
" transcript; restore the authoritative copy and a fresh prompt. The log is lines 1..len(s:transcript) and the input block
" must occupy at least the line below it, so any buffer shorter than that has
" had the prompt (and possibly log lines) eaten by backspace.
function! s:GuardTranscript()
  if s:guarding
    return
  endif
  if s:buf < 1 || !buflisted(s:buf) || empty(s:transcript)
    return
  endif
  " TextChanged also fires for the plugin's own streaming edits (they bump
  " changedtick).  The event is deferred to the next redraw, at which point
  " the cursor has moved on, so bail while the cursor sits in the prompt /
  " input block.
  if s:input_line > 0 && line('.') >= s:input_line
    return
  endif
  " The newest buffer edit was ours: s:transcript already reflects it, so
  " this TextChanged carries no user edit.  (User edits - typed or backspace
  " - always bump changedtick past s:plugin_tick and fall through to the
  " full compare below.)
  if getbufvar(s:buf, 'changedtick') == s:plugin_tick
    return
  endif
  let l:t = len(s:transcript)
  if s:NLines() < l:t + 1 || getbufline(s:buf, 1, l:t) !=# s:transcript
    let s:guarding = 1
    call s:SetLine(1, s:transcript + ['❯ '])
    call s:DeleteLines(l:t + 2, s:NLines())
    let s:input_line = l:t + 1
    let s:tail_line = 0
    let s:tail = ''
    " Reset the reentrancy flag before touching cursor/insert mode so the guard
    " cannot be left permanently stuck if anything below raises an error.
    let s:guarding = 0
    " The cursor belongs to the current window: only move it in the chat.
    if bufnr('%') != s:buf
      return
    endif
    if mode() =~# 'i'
      call cursor(s:input_line, s:InputCol(s:input_line))
      startinsert!
    else
      call cursor(s:input_line, 1)
    endif
  endif
endfunction

" Keep the ❯ prompt marker on the input line untouchable: the cursor can never
" sit at or before it, and the marker is restored the instant it is deleted or
" a character is typed in front of it.  Fires on every insert-mode text change
" and cursor move, so it covers backspace, the left arrow, the mouse and
" command-line escapes alike (s:GuardTranscript only protects the log lines).
function! s:PinInputCursor()
  if s:pinning
    return
  endif
  " While a turn is in flight the prompt glyph is intentionally blanked (the
  " user sees the in-chat working line instead); s:GuardBusyInput owns the
  " input line then, so do not restore the ❯ marker here.
  if s:busy
    return
  endif
  if s:buf < 1 || !buflisted(s:buf) || s:input_line < 1
    return
  endif
  if line('.') != s:input_line
    return
  endif
  let l:min = strlen('❯ ') + 1
  let l:line = getline(s:input_line)
  let l:restore = ''
  if strcharpart(l:line, 0, 1) !=# '❯'
    " the marker is gone (or junk was typed in front of it)
    let l:restore = '❯ ' . l:line
  elseif strcharpart(l:line, 1, 1) !=# ' '
    " the space after the marker was eaten
    let l:restore = '❯ ' . strcharpart(l:line, 1)
  endif
  if l:restore !=# '' || col('.') < l:min
    let s:pinning = 1
    if l:restore !=# ''
      call setline(s:input_line, l:restore)
    endif
    call cursor(s:input_line, min([l:min, col('$')]))
    let s:pinning = 0
  endif
endfunction

" While a turn is in flight (s:busy), typing on the prompt is ignored: the
" prompt glyph is hidden (the input line is blank) and any character typed
" (or continuation line opened with <C-CR>) is discarded, so the user cannot
" interleave edits with a streaming reply. :PiSend still works — it is an
" explicit queue, not typing.
function! s:GuardBusyInput()
  if s:typing_guard
    return
  endif
  if !s:busy
    return
  endif
  if s:buf < 1 || !buflisted(s:buf) || s:input_line < 1
    return
  endif
  if line('.') != s:input_line
    return
  endif
  " While a turn is in flight the prompt glyph is hidden (the input line is
  " blank); keep it that way by discarding anything typed on it.
  if getline(s:input_line) ==# '' && line('$') == s:input_line
    return
  endif
  let s:typing_guard = 1
  if line('$') > s:input_line
    execute s:input_line + 1 . ',' . line('$') . 'delete_'
  endif
  call setline(s:input_line, '')
  call cursor(s:input_line, 1)
  let s:typing_guard = 0
endfunction

" Reset the prompt block (input line down to the last line) to a single
" ❯ prompt. With keep=1 an existing half-typed ❯ line is preserved
" (resuming a parked session).
function! s:ClearInputBlock(keep)
  if s:buf < 1 || !buflisted(s:buf) || s:input_line < 1
    return
  endif
  call s:SyncInputLine()
  call s:DeleteLines(s:input_line + 1, s:NLines())
  if a:keep && s:Line(s:input_line) =~# '^❯'
    return
  endif
  call s:SetLine(s:input_line, '❯ ')
  call s:CaptureTranscript()
endfunction

function! s:JumpToBuf()
  let l:win = s:FindWin()
  if l:win > 0
    " Already visible in a window: just focus it.
    call win_gotoid(l:win)
  else
    " No window is showing the chat buffer (it was closed while the agent kept
    " running). Re-create a split and load the parked buffer into it rather
    " than taking over whatever window the user is editing in.
    call s:OpenWindow()
  endif
  call s:GotoInput()
endfunction

function! s:SetStatus(text)
  if s:buf > 0 && buflisted(s:buf)
    " setbufvar, not b:pi_status: the drain timer may run with any window
    " current, and a `let b:` would label the user's file buffer instead.
    call setbufvar(s:buf, 'pi_status', a:text)
    " Repaint here, not only from the spinner: the spinner stops at turn end,
    " so the final 'pi chat' would otherwise stay unpainted (the last spinner
    " frame lingers) until the next keystroke forces a redraw.
    call s:RedrawChatStatus()
  endif
endfunction

" Repaint the chat window's status line if it is on screen.  Plain
" redrawstatus only repaints the CURRENT window's status line, and timer
" ticks often run with another window current (the drain timer does not hop
" for spinner-only ticks), so use redrawstatus! there.  A hidden (parked)
" chat has nothing to repaint.
function! s:RedrawChatStatus()
  let l:win = s:FindWin()
  if l:win < 1
    return
  endif
  if win_getid() == l:win
    silent! redrawstatus
  else
    silent! redrawstatus!
  endif
endfunction

" Statusline helper. Must stay free of double quotes: it lives inside a
" 'statusline' %{...} expression, and some vim builds fail to parse such
" values when they contain quotes.
function! PiChatStatusText()
  if !exists('s:buf') || s:buf < 1 || !buflisted(s:buf)
    return ''
  endif
  let l:st = getbufvar(s:buf, 'pi_status')
  " getbufvar() returns the string itself (or '' when unset); never a list.
  let l:st = type(l:st) == v:t_string ? l:st : ''
  " Extension status entries (setStatus), in key order.
  if !empty(s:ext_status)
    let l:st .= '  · ' . join(map(sort(keys(s:ext_status)), 's:ext_status[v:val]'), ' · ')
  endif
  return l:st
endfunction

" Right-hand statusline part: the model pi is currently using, shown after
" the '=' separator so it floats right next to 'pi chat' / 'pi is working'.
" Same double-quote constraint as PiChatStatusText().
function! PiChatStatusModel()
  if !exists('s:model_label') || s:model_label ==# ''
    return ''
  endif
  return ' ' . s:model_label . ' '
endfunction

function! s:SetModelLabel(label)
  let s:model_label = a:label
  if s:buf > 0 && buflisted(s:buf)
    call s:RedrawChatStatus()
  endif
endfunction

" pi's Model object -> short display label 'provider/id' (falls back to the
" model name when either part is missing).
function! s:ModelLabelOf(model)
  if type(a:model) != v:t_dict
    return ''
  endif
  let l:prov = get(a:model, 'provider', '')
  let l:id = get(a:model, 'id', '')
  if l:prov !=# '' && l:id !=# ''
    return l:prov . '/' . l:id
  endif
  return get(a:model, 'name', '')
endfunction

" Pull the Model object out of a response payload: get_state and cycle_model
" carry it under data.model, while set_model's data IS the model object.
function! s:ModelObject(data)
  if type(a:data) != v:t_dict
    return {}
  endif
  if has_key(a:data, 'model') && type(a:data['model']) == v:t_dict
    return a:data['model']
  endif
  if has_key(a:data, 'id') && type(a:data['id']) == v:t_string
    return a:data
  endif
  return {}
endfunction

function! s:BusyStart()
  let s:busy = 1
  let s:busy_since = reltime()
  let s:spin = 0
  let s:running = 0
  let s:run_timeout_fired = 0
  call s:SpinnerUpdate()
endfunction

function! s:BusyStop()
  let s:busy = 0
  let s:busy_since = ''
endfunction

" Advances the spinner frame and refreshes the statusline text. Called on
" every drain tick (50ms) while a turn is in flight.
function! s:SpinnerUpdate()
  if !s:busy || empty(s:busy_since)
    return
  endif
  let l:sec = float2nr(reltimefloat(reltime()) - reltimefloat(s:busy_since))
  let l:label = s:running ? 'pi is working' : 'contacting pi'
  let l:text = s:spin_frames[s:spin] . ' ' . l:label . ' ' . l:sec . 's'
  if g:pi_chat_run_timeout > 0 && l:sec > g:pi_chat_run_timeout
    let l:text .= '  (long run: :PiClose to stop)'
    if !s:run_timeout_fired
      let s:run_timeout_fired = 1
      call s:WithChatWin({ -> s:AddLogLines(['', '⏱ pi run exceeded '
            \ . g:pi_chat_run_timeout . 's - may be stuck; :PiClose to force-stop']) })
    endif
  endif
  call s:SetStatus(l:text)
endfunction

" --------------------------- working indicator -----------------------------

" Show the in-chat '⏳ pi is working…' line at the start of a turn and blank
" the ❯ prompt line so the chat does not look idle while pi is generating.
" The working line is a committed log line (added via s:AddLogLines), so the
" streamed reply and tool lines all land below it; its buffer position is
" therefore stable for the whole turn, and s:HideWorking can find it again by
" searching for the ⏳ marker rather than tracking a shifting line number.
function! s:ShowWorking()
  if s:buf < 1 || !buflisted(s:buf) || s:input_line < 1
    return
  endif
  call s:AddLogLines(['⏳ pi is working…'])
  if s:input_line <= s:NLines()
    " Blank the whole input block (prompt + continuation lines): typing is
    " ignored while pi works; a half-typed block was stashed by the caller.
    call s:DeleteLines(s:input_line + 1, s:NLines())
    call s:SetLine(s:input_line, '')
  endif
endfunction

" Remove the working line (if still present) and restore the ❯ prompt.
" Idempotent: the marker search simply finds nothing when there is no working
" line, so it is safe to call from every turn-end path (settle, abort, clear).
" Searches upward from the input line for the nearest ⏳ marker — s:AddLogLines
" shifts absolute line numbers as the turn streams, so a stored number would
" go stale. After deletion the prompt block is restored on the input line:
" the half-typed text stashed in s:input_stash, else a bare ❯ prompt.
function! s:HideWorking()
  if s:buf < 1 || !buflisted(s:buf) || s:input_line < 1
    return
  endif
  let l:ln = 0
  " Search upward (toward the top of the buffer) from the input line for the
  " nearest working marker. The marker is the last ⏳ line above the prompt;
  " it may sit several lines up once the reply has streamed in below it.
  let l:log = s:input_line > 1 ? getbufline(s:buf, 1, s:input_line - 1) : []
  for l:i in range(len(l:log) - 1, 0, -1)
    if stridx(l:log[l:i], '⏳ pi is working') == 0
      let l:ln = l:i + 1
      break
    endif
  endfor
  if l:ln > 0
    call s:DeleteLines(l:ln, l:ln)
    let s:input_line -= 1
    if s:tail_line > l:ln
      let s:tail_line -= 1
    endif
  endif
  if s:input_line <= s:NLines()
    call s:RestoreInputBlock()
  endif
  call s:CaptureTranscript()
  call s:GuardTranscript()
endfunction

" Put the prompt block back on the input line: the stashed half-typed block
" (see s:StashInputBlock) if there is one, else a bare ❯ prompt.
function! s:RestoreInputBlock()
  let l:block = empty(s:input_stash) ? ['❯ '] : s:input_stash
  let s:input_stash = []
  call s:DeleteLines(s:input_line + 1, s:NLines())
  call s:SetLine(s:input_line, l:block[0])
  if len(l:block) > 1
    call s:AppendLines(s:input_line, l:block[1:])
  endif
endfunction

" Save the current prompt block if the user has typed something into it, so a
" prompt sent past it (:PiSend, :PiOpen <msg>) does not throw it away; it is
" put back when the turn ends (s:HideWorking).  While a turn is in flight the
" block is blank (typing is ignored), so an earlier stash is kept.
function! s:StashInputBlock()
  if s:buf < 1 || !bufloaded(s:buf) || s:input_line < 1
    return
  endif
  let l:block = getbufline(s:buf, s:input_line, '$')
  if !empty(l:block) && l:block[0] =~# '^❯' && l:block !=# ['❯ '] && l:block !=# ['❯']
    let s:input_stash = l:block
  endif
endfunction

" ------------------------------ thinking panel -----------------------------
" :PiThinking toggles a full-width horizontal panel at the screen bottom where the
" model's thinking streams live.  The panel is a separate, NOMODIFIABLE
" buffer, so the user can browse it (ctrl+w) but can't edit or delete
" streamed thinking.  This build makes setbufline/deletebufline honor that
" (E21), so programmatic writes run through s:ThinkBufWrite, which flips
" 'modifiable' for the duration of the write - the same quirk the chat
" transcript works around with s:GuardTranscript.  Writes go through
" buffer-local functions so a drain tick never steals focus, and the panel
" cursor is re-parked at the bottom on every flush, so the panel
" auto-scrolls while lines are still arriving.  Closing the panel keeps its
" content (bufhidden=hide), so toggling off/on mid-turn preserves what
" already streamed.  Each new prompt and :PiClear reset it; :PiClose
" destroys it.

function! s:ThinkPanelHeight()
  let l:h = get(g:, 'pi_chat_thinking_height', 0.3)
  " A float in (0, 1) is a fraction of the screen height.  (This used to
  " test v:t_number, which a float never is, so the default 0.3 always fell
  " through to 8 rows.)
  if type(l:h) == v:t_float && l:h > 0 && l:h < 1
    return max([1, float2nr(&lines * l:h)])
  endif
  return (type(l:h) == v:t_number && l:h > 0) ? l:h : 8
endfunction

" Called with the panel buffer current (right after `:buffer`).
function! s:ThinkBufInit()
  setlocal buftype=nofile bufhidden=hide noswapfile nonumber norelativenumber nospell
  setlocal wrap linebreak foldcolumn=0
  " `let &l:statusline` is the only form that sticks for values containing
  " spaces in this vim: `:setlocal statusline='… …'` raises E518 (value split
  " on spaces) and the double-quoted :setlocal form is silently dropped.
  let &l:statusline = ' pi thinking '
  " Markdown highlighting (headings, bold/italic, code, lists, links) —
  " buffer-local, layered on when g:pi_chat_markdown is on.
  call s:ApplyMarkdown()
endfunction

" Number of lines in the panel buffer (getbufline-based: buflinecount() is
" not built into every Vim 9.2).
function! s:ThinkLineCount()
  return len(getbufline(s:think_buf, 1, '$'))
endfunction

function! s:ThinkReset()
  let s:think_text = ''
  let s:think_frag = ''
  let s:think_lines = 0
  let s:think_synced = 0
  let s:think_pending = []
  let s:think_synced_text = ''
  let s:think_dirty = 0
  if s:think_buf < 0 || !bufexists(s:think_buf)
    return
  endif
  call s:ThinkBufWrite({ -> s:ThinkBufClear() })
  let s:think_synced = 1
  let s:think_lines = 1
endfunction

" a new prompt appends a marker line instead of clearing, so the panel keeps
" the conversation's thinking history, each turn under its prompt marker.
" The marker lands mid-stream (before the in-flight fragment), so this is a
" full re-render - but it happens once per prompt, not per delta.
function! s:ThinkNewTurn(text)
  call s:ThinkMergePending()
  let l:head = '──── ' . substitute(a:text, '\n', ' ', 'g')
  if empty(s:think_text)
    let s:think_text = l:head . "\n"
  else
    let s:think_text .= "\n" . l:head . "\n"
  endif
  call s:ThinkRenderFull()
endfunction

" Runs a:func with the panel buffer temporarily modifiable.  The buffer is
" nomodifiable so the user can't edit streamed thinking, but this build
" makes setbufline/deletebufline fail with E21 on such buffers, so every
" programmatic write flips the option for the duration of the closure.
function! s:ThinkBufWrite(func)
  call setbufvar(s:think_buf, '&modifiable', 1)
  try
    call a:func()
  finally
    call setbufvar(s:think_buf, '&modifiable', 0)
  endtry
endfunction

" (Re)writes the panel buffer's lines to a:lines.  Only called with the
" buffer temporarily modifiable (see s:ThinkBufWrite).
function! s:ThinkBufSync(lines)
  for l:i in range(1, len(a:lines))
    call setbufline(s:think_buf, l:i, a:lines[l:i - 1])
  endfor
  let l:old = s:ThinkLineCount()
  if l:old > len(a:lines)
    call deletebufline(s:think_buf, len(a:lines) + 1, l:old)
  endif
endfunction

" Empties the panel buffer back to a single blank line.
function! s:ThinkBufClear()
  call setbufline(s:think_buf, 1, '')
  let l:n = s:ThinkLineCount()
  if l:n > 1
    call deletebufline(s:think_buf, 2, l:n)
  endif
endfunction

" Re-renders the panel buffer from scratch out of s:think_text: every
" complete line plus the trailing in-flight fragment (empty text renders as
" the single placeholder blank line a fresh buffer starts with).  Called on
" panel open, after a reset, on session resume, and for the once-per-prompt
" turn marker - not per delta (that's s:ThinkAppendDelta).
function! s:ThinkRenderFull()
  if s:think_buf < 0 || !bufexists(s:think_buf)
    return
  endif
  call s:ThinkMergePending()
  let l:parts = split(s:think_text, "\n", 1)
  let s:think_frag = l:parts[-1]
  let l:render = copy(l:parts)
  if l:render[-1] ==# ''
    " remove() honours negative indexes; list slicing (render[:-1]) does not
    " in this build and silently returns the whole list.
    call remove(l:render, -1)
  endif
  if empty(l:render)
    let l:render = ['']
  endif
  call s:ThinkBufWrite({ -> s:ThinkBufSync(l:render) })
  let s:think_lines = len(l:render)
  let s:think_synced = 1
  let s:think_synced_text = s:think_text
  call s:ThinkParkCursor()
endfunction

" Folds the unflushed delta list into s:think_text.  Appending the whole
" list with one join keeps the per-delta cost O(delta) instead of O(n) per
" string concatenation.
function! s:ThinkMergePending()
  if empty(s:think_pending)
    return
  endif
  let s:think_text .= join(s:think_pending, '')
  let s:think_pending = []
endfunction

" Panel invariant: the buffer holds split(s:think_text, "\n", 1) with the
" trailing '' dropped - the complete lines plus the in-flight fragment - or
" the single placeholder blank line while s:think_text is empty.
" Appends one thinking delta: O(1) list push, no buffer or window work at
" all.  s:ThinkFlush (end of each drain tick) is the only place the panel
" buffer is touched, so a long stream costs O(delta) per tick instead of
" O(n) per delta.
function! s:ThinkAppendDelta(delta)
  if a:delta ==# ''
    return
  endif
  call add(s:think_pending, a:delta)
  if s:think_buf > 0 && bufexists(s:think_buf) && s:think_synced
    let s:think_dirty = 1
  endif
endfunction

" Flushed once per drain tick: merges the pending deltas into
" s:think_text and brings the panel buffer up to date in ONE pass - one
" modifiable toggle, one append for the new lines, one cursor park.
function! s:ThinkFlush()
  if !s:think_dirty || empty(s:think_pending)
    return
  endif
  if s:think_buf < 0 || !bufexists(s:think_buf) || !s:think_synced
    return
  endif
  let l:placeholder = (s:think_synced_text ==# '')
  call s:ThinkMergePending()
  let l:new = strpart(s:think_text, strlen(s:think_synced_text))
  let l:parts = split(l:new, "\n", 1)
  if empty(s:think_frag)
    " the buffer's last line is complete (or the placeholder): every part
    " is a fresh line
    let l:target = copy(l:parts)
  else
    " the buffer's last line is the in-flight fragment: the first part
    " extends it
    let l:target = [s:think_frag . l:parts[0]] + l:parts[1:]
  endif
  if l:target[-1] ==# ''
    " remove() honours negative indexes; list slicing ([:-1]) does not in
    " this build and silently returns the whole list.
    call remove(l:target, -1)
  endif
  let s:think_dirty = 0
  let s:think_synced_text = s:think_text
  if empty(l:target)
    return
  endif
  let l:extend = !empty(s:think_frag)
  call s:ThinkBufWrite({ -> s:ThinkApplyTarget(l:target, l:extend, l:placeholder) })
  let s:think_frag = (s:think_text =~# '\n$') ? '' : l:target[-1]
  let s:think_lines += l:extend ? len(l:target) - 1
        \ : l:placeholder ? len(l:target) - 1 : len(l:target)
  call s:ThinkParkCursor()
endfunction

" Applies the flushed lines to the panel buffer.  Only called with the
" buffer temporarily modifiable (s:ThinkBufWrite); s:think_lines is the
" buffer's current line count.
function! s:ThinkApplyTarget(target, extend, placeholder)
  if a:extend
    " extend the in-flight last line, then append the rest
    call setbufline(s:think_buf, s:think_lines, a:target[0])
    if len(a:target) > 1
      call appendbufline(s:think_buf, s:think_lines, a:target[1:])
    endif
  elseif a:placeholder
    " replace the placeholder blank line
    call setbufline(s:think_buf, 1, a:target[0])
    if len(a:target) > 1
      call appendbufline(s:think_buf, 1, a:target[1:])
    endif
  else
    " the last line is complete: append everything as new lines
    call appendbufline(s:think_buf, s:think_lines, a:target)
  endif
endfunction

" Parks the panel's cursor on its last line, so while the model is still
" thinking the panel auto-scrolls to the newest line; once the stream
" settles the user is free to scroll back up (the buffer is nomodifiable,
" so browsing can't clobber the content).  A win_gotoid hop: this build's
" cursor() has no {win} argument (cursor(w, n) silently acts on the CURRENT
" window), and redraw is deferred until the hop returns, so it never steals
" focus from the user's active window.
function! s:ThinkParkCursor()
  if s:think_buf < 0
    return
  endif
  let l:win = bufwinid(s:think_buf)
  if l:win > 0
    let l:here = win_getid()
    noautocmd call win_gotoid(l:win)
    call cursor(max([1, s:think_lines]), 1)
    noautocmd call win_gotoid(l:here)
  endif
endfunction

function! s:ThinkCloseAll()
  if s:think_buf < 0
    return
  endif
  let l:winid = bufwinid(s:think_buf)
  if l:winid > 0
    execute win_id2win(l:winid) . 'wincmd w'
    if winnr('$') > 1
      close
    endif
  endif
  " :bwipeout takes a literal buffer name/number (`bdelete! s:think_buf`
  " looked for a buffer NAMED 's:think_buf', so the panel - and the closed
  " session's thinking - survived into the next :PiOpen).
  if bufexists(s:think_buf)
    execute 'silent! bwipeout! ' . s:think_buf
  endif
  if has_key(s:md_done, s:think_buf)
    call remove(s:md_done, s:think_buf)
  endif
  let s:think_buf = -1
  let s:think_text = ''
  let s:think_frag = ''
  let s:think_lines = 0
  let s:think_synced = 0
  let s:think_pending = []
  let s:think_synced_text = ''
  let s:think_dirty = 0
endfunction

" ------------------- markdown highlighting (in-place, buffer-local) ---------

" Apply buffer-local markdown syntax to the current buffer, once per buffer.
" Purely visual (syn + hi link) — never touches buffer text, so the chat
" input line, transcript guards and streaming pipeline are unaffected.
function! s:ApplyMarkdown()
  if !get(g:, 'pi_chat_markdown', 1)
    return
  endif
  let l:b = bufnr('%')
  if has_key(s:md_done, l:b)
    return
  endif
  let s:md_done[l:b] = 1
  syn match PiMdFence     '^\s*```\S*'
  syn region PiMdCodeBlock start=/^\s*```/ end=/^\s*```/ contains=PiMdFence keepend
  syn match PiMdHeading   '^#\+\s\+\S.*\|^#\+\s*$'
  " PiMdItalic must be defined BEFORE PiMdBold: when both match the same
  " bytes (the inner *text* of **text**), the last-defined item wins per
  " byte, so defining bold last keeps **text** bold instead of italic.
  syn match PiMdItalic    '\*\S[^*]*\S\*\|\*\S[^*]*$'
  syn match PiMdBold      '\*\*\S.*\S\*\*'
  syn match PiMdCode      '`[^`]\+`'
  syn match PiMdList      '^\s*[-*+]\s\|^\s*[0-9]\+\.\s'
  syn match PiMdQuote     '^>.*'
  syn match PiMdLink      '\[[^]]*\]([^)]*)'
  hi def link PiMdHeading   Title
  hi def link PiMdBold      Bold
  hi def link PiMdItalic    Italic
  hi def link PiMdCode      Special
  hi def link PiMdCodeBlock Special
  hi def link PiMdFence     Comment
  hi def link PiMdList      Keyword
  hi def link PiMdQuote     Comment
  hi def link PiMdLink      Underlined
endfunction

" :PiOpen opens both panels: show the thinking view if it isn't already open.
function! s:PiShowThinking()
  if s:think_buf > 0 && bufwinnr(s:think_buf) != -1
    return
  endif
  call s:PiThinking()
endfunction

function! s:PiThinking()
  if s:think_buf > 0 && bufwinnr(s:think_buf) != -1
    " toggle off: the window closes, the buffer (and its content) survives
    call win_gotoid(bufwinid(s:think_buf))
    if winnr('$') > 1
      close
    endif
    echo 'thinking panel hidden (content kept)'
    return
  endif
  if s:buf < 0
    echohl WarningMsg | echo 'pi chat: open the chat first (:PiOpen)' | echohl None
    return
  endif
  let l:first = (s:think_buf < 0)
  if l:first
    let s:think_buf = bufadd('__PiChatThinking__')
    call bufload(s:think_buf)
    " Read-only for the user: ctrl+w into the panel is fine for reading, but
    " typing/deleting streamed thinking is refused (E519).  Start empty even
    " if a leftover buffer of that name still exists (and is nomodifiable).
    call s:ThinkBufWrite({ -> s:ThinkBufClear() })
  endif
  " open the panel as a full-width window at the bottom (botright)
  " win_gotoid jumps to the window by ID. (execute l:winid . 'wincmd w' would
  " instead run wincmd w winid TIMES - a cyclic hop, not a jump.)
  let l:cwin = s:FindWin()
  if l:cwin > 0
    call win_gotoid(l:cwin)
  endif
  botright split
  execute 'resize ' . s:ThinkPanelHeight()
  execute 'buffer ' . s:think_buf
  call s:ThinkBufInit()
  if l:cwin > 0
    call win_gotoid(l:cwin)
  endif
  " render any thinking that accumulated before the panel existed (the
  " render parks the cursor too), then always park at the bottom so the next
  " delta is followed; via win_gotoid hops since this build's cursor() has no
  " {win} form
  call s:ThinkRenderFull()
  let l:win = bufwinid(s:think_buf)
  if l:win > 0
    let l:here = win_getid()
    call win_gotoid(l:win)
    call cursor(s:ThinkLineCount(), 1)
    call win_gotoid(l:here)
  endif
endfunction

" ------------------------------- commands/maps -----------------------------

command!          PiThinking call s:PiThinking()

" <q-args> is always a valid string (empty when no args): `:PiOpen fix the
" bug` passes the whole phrase, and `:PiOpen "quoted: words"` still arrives as
" a single quoted argument.
command! -nargs=* PiOpen  call s:PiOpen(<q-args>)
command! -nargs=* PiSend  call s:PiSend(<q-args>)
command!          PiAbort call s:PiAbort()
command!          PiClear call s:PiClear()
command!          PiRestart call s:PiRestart()
command!          PiClose call s:PiClose()
command! -nargs=? -complete=file PiFile call s:PiFile(<f-args>)

if !empty(g:pi_chat_map) && maparg(g:pi_chat_map, 'n') ==# ''
  execute printf('nnoremap <silent> %s :PiOpen<CR>', g:pi_chat_map)
endif

" Track the user switching to a different file (:e, :b, tab switching to a
" file buffer, ...): keep the context file in sync and tell pi about it, so
" the agent's next turn works on the file the user is actually looking at.
augroup PiChatFileTrack
  autocmd!
  " PanelGuard first: the panel must be back in its window before OnFileEnter
  " logs the switch (the log is appended to the chat window's buffer).
  autocmd BufEnter * call s:PanelGuard()
  autocmd BufEnter * call s:OnFileEnter()
augroup END

" Quitting the last real window of a tab (g:pi_chat_quit_with_last_window).
augroup PiChatQuit
  autocmd!
  autocmd QuitPre * call s:OnQuitPre()
augroup END

function! s:IsPanelWin(winid)
  let l:b = winbufnr(a:winid)
  return l:b > 0 && (l:b == s:buf || l:b == s:think_buf)
endfunction

" QuitPre fires for :quit, :exit/:xit, :wq and ZZ - before Vim decides
" whether the command closes just this window or exits - but not for :close
" or :only.  When the window being quit is the tab's last real window and
" everything else there is a pi panel, close the panels first: the command
" then exits Vim (or closes the tab), as it would without the plugin.  Quits
" from inside a panel keep their meaning (closing the chat parks the agent).
" If the quit then fails (E37: unsaved changes), the panels stay closed;
" :PiOpen brings them back with the transcript intact.
function! s:OnQuitPre()
  if !get(g:, 'pi_chat_quit_with_last_window', 1) || s:IsPanelWin(win_getid())
    return
  endif
  let l:here = win_getid()
  let l:panels = []
  for l:w in gettabinfo(tabpagenr())[0].windows
    if l:w == l:here
      continue
    endif
    if !s:IsPanelWin(l:w)
      " Another real window remains: :q just closes this one, as usual.
      return
    endif
    call add(l:panels, l:w)
  endfor
  for l:w in l:panels
    let l:nr = win_id2win(l:w)
    if l:nr > 0
      execute l:nr . 'close'
    endif
  endfor
endfunction

" ------------------------------ job control --------------------------------

function! s:UserPrompt(text)
  " a new prompt starts a fresh thinking block; earlier turns stay visible
  call s:ThinkNewTurn(a:text)
  " :PiSend / :PiOpen <msg> send past whatever the user was typing on the ❯
  " prompt: keep it (restored when the turn ends) instead of wiping it.  The
  " <CR> path already consumed its block, so there is nothing to stash there.
  call s:StashInputBlock()
  call s:ClearInputBlock(0)
  call s:AddLogLines(['', '❯ ' . a:text])
  " A prompt sent while a turn is in flight is queued by pi (followUp/steer)
  " and pi emits ONE agent_settled once the queue drains, so the turn keeps
  " its single ⏳ line and its busy clock: a second line would never be
  " removed.
  let l:queued = s:busy
  if !l:queued
    call s:ShowWorking()
  endif
  call s:CaptureTranscript()
  call s:EnsureContextSaved()
  " The agent never sees the Vim buffer list, so tell it which file the user is
  " working on; pi's read/edit tools do the rest. Unsaved buffers count too:
  " the path tells pi where to create the file.
  let l:msg = a:text
  " After a file switch (g:pi_chat_track_files) the first prompt says so.
  let l:lead = s:switch_pending ? s:ctx_lead_switched : s:ctx_lead_is
  let l:told = 0
  if g:pi_chat_context_file
    let l:ctx = s:context_file
    if l:ctx ==# ''
      " No captured context file (bare `vim`): fall back to the alternate
      " buffer, i.e. whatever the user was viewing before the chat window.
      let l:ctx = expand('#:p')
    endif
    if l:ctx !=# '' && isdirectory(fnamemodify(l:ctx, ':h'))
      let l:told = 1
      if filereadable(l:ctx)
        let l:msg = l:lead . l:ctx . s:ctx_hint_edit . "\n" . a:text
      else
        let l:msg = l:lead . l:ctx . s:ctx_hint_new . "\n" . a:text
      endif
    endif
  endif
  if s:switch_pending && !l:told && s:context_file !=# ''
    " Context injection is off, but the user did switch files: still say so.
    let l:msg = l:lead . s:context_file . s:ctx_hint_read . "\n" . a:text
  endif
  let l:cmd = {'type': 'prompt', 'message': l:msg}
  if g:pi_chat_streaming_behavior !=# ''
    let l:cmd.streamingBehavior = g:pi_chat_streaming_behavior
  endif
  " Only arm the busy state when the prompt actually reached the channel:
  " a failed send (dead agent) would otherwise leave the spinner running
  " and the input guard discarding every keystroke until vim is restarted.
  let l:sent = s:Send(l:cmd)
  if l:sent
    let s:switch_pending = 0
  endif
  if l:sent && !l:queued
    call s:BusyStart()
  endif
endfunction

function! s:HasJob()
  return pi_chat_compat#IsJob(s:job)
endfunction

" job_status() is 'run', 'fail' (could not start) or 'dead'.
function! s:JobAlive()
  return s:HasJob() && pi_chat_compat#JobAlive(s:job)
endfunction

" Returns 1 if the command reached the channel, 0 on failure. A failed send
" (agent dead or channel broken) clears the working state, so a prompt sent
" into a dead agent cannot leave the panel stuck with a permanent spinner
" and a busy input guard swallowing every keystroke until vim is restarted.
function! s:Send(dict)
  if !s:JobAlive()
    call s:SendFail('agent process is not running (use :PiOpen)')
    return 0
  endif
  let l:payload = a:dict
  " Commands get a fresh correlation id; an extension_ui_response already
  " carries the id of the request it answers and must keep it (overwriting
  " it meant pi never matched any dialog answer).
  if !has_key(l:payload, 'id')
    let s:req_id += 1
    let l:payload.id = 'req-' . s:req_id
  endif
  try
    call pi_chat_compat#ChSend(s:job, json_encode(l:payload) . "\n")
    return 1
  catch
    call s:SendFail('failed to talk to pi: ' . v:exception .
          \ ' (use :PiClear to restart the agent)')
    return 0
  endtry
endfunction

function! s:SendFail(msg)
  call s:HideWorking()
  call s:BusyStop()
  call s:AddLogLines(['', '⚠ ' . a:msg])
endfunction

" Spawns `pi --mode rpc` as a background job. Output arrives line by line
" through the out_cb/err_cb callbacks; stdin stays open for commands.
" pi's session store directory (where <encoded-cwd>/<ts>_<id>.jsonl live).
function! s:SessionBaseDir() abort
  if g:pi_chat_session_dir !=# ''
    return fnamemodify(g:pi_chat_session_dir, ':p')
  endif
  return expand('~/.pi/agent/sessions')
endfunction

" Stable, filesystem- and glob-safe id derived from a path:
" 'pchat-<len>-<sha256>' of the resolved absolute path (deterministic, so the
" same file always -> same id, and distinct paths never share one).
function! s:DeriveSessionId(path) abort
  let l:p = s:SessionPath(a:path)
  return printf('pchat-%d-%s', strlen(l:p), sha256(l:p))
endfunction

function! s:SessionPath(path) abort
  let l:p = resolve(fnamemodify(a:path, ':p'))
  " ':p' keeps a trailing slash on directories; drop it so 'dir' and 'dir/'
  " map to the same id.
  return len(l:p) > 1 ? substitute(l:p, '/$', '', '') : l:p
endfunction

" A path's session id if pi already has a session for it, else ''.
function! s:ExistingSessionId(path) abort
  let l:id = s:DeriveSessionId(a:path)
  return s:SessionExists(l:id) ? l:id : ''
endfunction

function! s:SessionExists(sid) abort
  if a:sid ==# ''
    return 0
  endif
  return !empty(glob(s:SessionBaseDir() . '/*/*' . a:sid . '.jsonl', 1, 1))
endfunction

" File first, else its parent dir's session, else a fresh file-keyed id.
" Returns [id, kind] where kind is 'file', 'dir' or 'new'.
function! s:ChooseSessionId(context_file) abort
  " base is the context file, or the working directory when no file was opened.
  let l:base = a:context_file !=# '' ? a:context_file : getcwd()
  let l:base_id = s:DeriveSessionId(l:base)
  let l:found = s:ExistingSessionId(l:base)
  if isdirectory(l:base)
    " No context file (cwd) or a directory context: the folder tier.
    return l:found !=# '' ? [l:found, 'dir'] : [l:base_id, 'new']
  endif
  " base is a file: tier 1 = its own session, tier 2 = its parent dir's.
  if l:found !=# ''
    return [l:found, 'file']
  endif
  if g:pi_chat_session_fallback_dir
    let l:dir_id = s:ExistingSessionId(fnamemodify(l:base, ':h'))
    if l:dir_id !=# ''
      return [l:dir_id, 'dir']
    endif
  endif
  " Nothing to resume: key to the file (a new session will be created there).
  return [l:base_id, 'new']
endfunction

" The context prefix s:UserPrompt puts in front of every prompt (pi never
" sees the Vim buffer list, so it is told which file the user works on).
" One place for the wording, so s:StripContextPrefix can take it back off
" when a session is replayed.
let s:ctx_lead_is = 'The file I am working on is: '
let s:ctx_lead_switched = 'I switched the file I am working on to: '
let s:ctx_hint_edit = ' (read it if you need its contents; edit it in place when asked).'
let s:ctx_hint_new = ' (not saved to disk yet; create it when I ask for new content).'
let s:ctx_hint_read = ' (read it if you need its contents).'

function! s:ReEscape(text) abort
  return escape(a:text, '\.*$^~[]')
endfunction

" A replayed user message minus the plugin's context prefix: returns
" [text, switched_to] - switched_to is the path of a bare file-switch notice
" (the whole message; older sessions sent those as prompts of their own).
function! s:StripContextPrefix(text) abort
  let l:leads = s:ReEscape(s:ctx_lead_is) . '\|' . s:ReEscape(s:ctx_lead_switched)
  let l:hints = join(map([s:ctx_hint_edit, s:ctx_hint_new, s:ctx_hint_read],
        \ 's:ReEscape(v:val)'), '\|')
  let l:bare = '^' . s:ReEscape(s:ctx_lead_switched) . '\(.\{-}\)\%(' . l:hints . '\)$'
  if a:text =~# l:bare
    return ['', matchlist(a:text, l:bare)[1]]
  endif
  return [substitute(a:text, '^\%(' . l:leads . '\).\{-}\%(' . l:hints . '\)\n', '', ''), '']
endfunction

" The user/assistant messages on a saved session's ACTIVE branch, in order.
" A pi session file is a tree (entries link to their parent through
" id/parentId; branching keeps the abandoned paths in the file) and the
" current position - the leaf - is the last entry written, so walk from it
" up to the root.  Files without ids (v1 sessions, hand-written fixtures)
" are read linearly.
function! s:SessionMessages(sid) abort
  if empty(a:sid)
    return []
  endif
  let l:files = glob(s:SessionBaseDir() . '/*/*' . a:sid . '.jsonl', 1, 1)
  if type(l:files) == v:t_string
    let l:files = split(l:files, "\n")
  endif
  if empty(l:files)
    return []
  endif
  let l:entries = []
  let l:byid = {}
  let l:leaf = ''
  for l:raw in readfile(l:files[0])
    try
      let l:e = json_decode(l:raw)
    catch
      continue
    endtry
    if type(l:e) != v:t_dict || get(l:e, 'type', '') ==# 'session'
      continue
    endif
    call add(l:entries, l:e)
    let l:id = get(l:e, 'id', '')
    if type(l:id) == v:t_string && l:id !=# ''
      let l:byid[l:id] = l:e
      let l:leaf = l:id
    endif
  endfor
  let l:onpath = {}
  let l:cur = l:leaf
  while l:cur !=# '' && has_key(l:byid, l:cur) && !has_key(l:onpath, l:cur)
    let l:onpath[l:cur] = 1
    let l:parent = get(l:byid[l:cur], 'parentId', v:null)
    let l:cur = type(l:parent) == v:t_string ? l:parent : ''
  endwhile
  let l:out = []
  for l:e in l:entries
    if get(l:e, 'type', '') !=# 'message'
      continue
    endif
    if l:leaf !=# '' && !has_key(l:onpath, get(l:e, 'id', ''))
      continue
    endif
    let l:msg = get(l:e, 'message', {})
    if type(l:msg) == v:t_dict && index(['user', 'assistant'], get(l:msg, 'role', '')) >= 0
      call add(l:out, l:msg)
    endif
  endfor
  return l:out
endfunction

" Render a saved pi session's user/assistant conversation as chat lines so a
" resumed session shows its prior history above the input line - laid out
" like the live chat: a blank line and '❯ <what you typed>' per prompt (the
" plugin's context prefix stripped again), then the reply.
function! s:LoadSessionTranscript(sid) abort
  let l:turns = []
  for l:msg in s:SessionMessages(a:sid)
    let l:text = s:MessageText(l:msg)
    if empty(l:text)
      continue
    endif
    if get(l:msg, 'role', '') ==# 'user'
      let [l:text, l:switched] = s:StripContextPrefix(l:text)
      if l:switched !=# ''
        call add(l:turns, ['', 'pi-chat: context file switched: ' . l:switched])
      elseif l:text !=# ''
        call add(l:turns, ['', '❯ ' . l:text])
      endif
    else
      call add(l:turns, [l:text])
    endif
  endfor
  " Cap the resumed transcript to the most recent N messages so a long session
  " never floods the chat buffer on open (0 = no cap).
  let l:cap = get(g:, 'pi_chat_resume_max_messages', 50)
  if type(l:cap) == v:t_number && l:cap > 0 && len(l:turns) > l:cap
    let l:turns = l:turns[len(l:turns) - l:cap :]
  endif
  let l:out = []
  for l:t in l:turns
    call extend(l:out, l:t)
  endfor
  return l:out
endfunction

" Prior thinking for a session, in order: for each assistant thinking block, a
" '──── <prompt>' marker (the flattened user message that preceded it, so the
" resumed panel reads like the live one) followed by the thinking text.
function! s:LoadSessionThinking(sid) abort
  let l:entries = []
  let l:last_user = ''
  for l:msg in s:SessionMessages(a:sid)
    if get(l:msg, 'role', '') ==# 'user'
      let l:utext = s:StripContextPrefix(s:MessageText(l:msg))[0]
      if !empty(l:utext)
        let l:last_user = substitute(l:utext, '\n', ' ', 'g')
      endif
    else
      let l:think = s:MessageThinking(l:msg)
      if !empty(l:think)
        let l:sec = []
        if !empty(l:last_user)
          call add(l:sec, '──── ' . l:last_user)
        endif
        call add(l:sec, l:think)
        call add(l:entries, l:sec)
      endif
    endif
  endfor
  let l:cap = get(g:, 'pi_chat_resume_max_messages', 50)
  if type(l:cap) == v:t_number && l:cap > 0 && len(l:entries) > l:cap
    let l:entries = l:entries[len(l:entries) - l:cap :]
  endif
  let l:out = []
  for l:sec in l:entries
    call extend(l:out, l:sec)
  endfor
  return l:out
endfunction

" Readable text of a session message (a plain string or a list of content
" blocks), keeping only text blocks so the replay reads as a clean conversation.
function! s:MessageText(msg) abort
  if type(a:msg) != v:t_dict
    return ''
  endif
  let l:content = get(a:msg, 'content', '')
  if type(l:content) == v:t_string
    return l:content
  endif
  if type(l:content) != v:t_list
    return ''
  endif
  let l:parts = []
  for l:block in l:content
    if type(l:block) == v:t_dict && get(l:block, 'type', '') ==# 'text'
      let l:t = get(l:block, 'text', '')
      if !empty(l:t)
        call add(l:parts, l:t)
      endif
    endif
  endfor
  return join(l:parts, "\n")
endfunction

" Thinking text of a session message: the 'thinking' content blocks of an
" assistant message, joined (empty for messages without any).
function! s:MessageThinking(msg) abort
  if type(a:msg) != v:t_dict
    return ''
  endif
  let l:content = get(a:msg, 'content', '')
  if type(l:content) != v:t_list
    return ''
  endif
  let l:parts = []
  for l:block in l:content
    if type(l:block) == v:t_dict && get(l:block, 'type', '') ==# 'thinking'
      let l:t = get(l:block, 'thinking', '')
      if !empty(l:t)
        call add(l:parts, l:t)
      endif
    endif
  endfor
  return join(l:parts, "\n")
endfunction

function! s:StartJob()
  " Consume the quiet flag up front: a failed job start must not leave it
  " set for a later, explicit :PiOpen.
  let l:quiet = s:quiet
  let s:quiet = 0
  if !executable('pi')
    echohl ErrorMsg
    echomsg 'pi-chat: pi executable not found on PATH'
    echohl None
    return
  endif

  " A brand-new conversation has no earlier file to have switched from.
  if s:fresh || s:clear_new_session
    let s:switch_pending = 0
  endif

  " s:OpenWindow() puts the chat buffer in a window, which fires its
  " BufWinEnter -> s:ChatWinGained().  That must not start a second job
  " underneath this one (the outer call would then overwrite s:job and
  " orphan the inner pi process), so flag the start in progress.
  let s:starting = 1
  try
    call s:OpenWindow()
  finally
    let s:starting = 0
  endtry
  " Never leave a live process behind: a caller that restarts the agent
  " without stopping it first would otherwise orphan it.
  if s:JobAlive()
    call s:StopJob()
  endif

  " A restarted process has no memory of the old one: drop a stale working
  " line / busy flag left behind if the agent died while a send was in
  " flight, so the :PiOpen recovery path always lands on a usable panel.
  " A half-typed prompt is stashed first so the reset puts it back.  (A
  " brand-new buffer has nothing to recover: resetting it there left a dead
  " duplicate ❯ line under the header.)
  if !s:fresh
    call s:StashInputBlock()
    call s:HideWorking()
  endif
  call s:BusyStop()

  let s:running = 0
  let s:queue = []
  let s:tail = ''
  let s:tail_line = 0
  " A new process starts with fresh extensions: drop their old status.
  let s:ext_status = {}
  call s:SetStatus('pi chat')

  let l:cmd = ['pi', '--mode', 'rpc']
  let s:resumed_kind = ''
  if g:pi_chat_no_session
    call add(l:cmd, '--no-session')
    let s:session_id = ''
  elseif g:pi_chat_session_resume
    let [l:sid, s:resumed_kind] = s:ChooseSessionId(s:context_file)
    if s:clear_new_session
      " :PiClear restarts the process for a fresh session instead of sending
      " pi an in-process `new_session` command: replacing the session
      " invalidates the context objects that loaded extensions keep, and
      " pi-observational-memory then throws "stale ctx" in
      " maybeTriggerCompaction on the next settled turn and exits the agent
      " with code 1.  A fresh process has a fresh context.
      "
      " The pre-clear session file for this id is deleted before launch:
      " create-or-resume with the id then starts a *new* session, but under
      " the same stable context-keyed id, so a later :PiOpen (even after a
      " full vim restart) resumes the post-clear session.  An ad-hoc id
      " would orphan the context mapping and make the next open resume the
      " pre-clear session instead.
      "
      " Only the context's OWN session is cleared: when a file had inherited
      " its folder's conversation (kind 'dir'), that folder session belongs
      " to every file in the folder and is left untouched; the file gets its
      " own fresh session instead.
      let l:base = s:context_file !=# '' ? s:context_file : getcwd()
      let l:sid = s:DeriveSessionId(l:base)
      let l:old_files = glob(s:SessionBaseDir() . '/*/*' . l:sid . '.jsonl', 1, 1)
      if type(l:old_files) == v:t_string
        let l:old_files = split(l:old_files, "\n")
      endif
      for l:old in l:old_files
        call delete(l:old)
      endfor
      let s:resumed_kind = ''
    endif
    let s:session_id = l:sid
    call extend(l:cmd, ['--session-id', l:sid])
  else
    let s:session_id = ''
  endif
  let s:clear_new_session = 0
  " Master prompt (g:pi_chat_master_prompt): standing rules appended to pi's
  " system prompt for the whole session. A readable file path is passed as a
  " path (pi loads its contents; expand ~ and make it absolute since pi
  " resolves relative paths from the job's cwd, not vim's); anything else is
  " treated as inline text, which is pi's own fallback for --append-system-prompt.
  if !empty(g:pi_chat_master_prompt)
    let l:mp = expand(g:pi_chat_master_prompt, 1)
    if filereadable(l:mp)
      call extend(l:cmd, ['--append-system-prompt', fnamemodify(l:mp, ':p')])
    else
      call extend(l:cmd, ['--append-system-prompt', g:pi_chat_master_prompt])
    endif
  endif
  call extend(l:cmd, g:pi_chat_args)

  let l:opts = {
        \ 'out_cb': function('s:OnOut'),
        \ 'err_cb': function('s:OnErr'),
        \ 'exit_cb': function('s:OnExit'),
        \ 'out_mode': 'nl',
        \ 'err_mode': 'nl',
        \ }
  " Run pi in the context file's directory so its file tools resolve relative
  " paths the way the user expects. (Ignored if that dir is gone.)
  if s:context_file !=# '' && isdirectory(fnamemodify(s:context_file, ':h'))
    let l:opts.cwd = fnamemodify(s:context_file, ':h')
  endif
  try
    " The command is a List: no shell is involved, so no quoting is needed.
    let s:job = pi_chat_compat#JobStart(l:cmd, l:opts)
  catch
    let s:job = v:null
    echohl ErrorMsg
    echomsg 'pi-chat: failed to start pi: ' . v:exception
    echohl None
    return
  endtry
  if !pi_chat_compat#IsJob(s:job)
    let s:job = v:null
    echohl ErrorMsg
    echomsg 'pi-chat: failed to start pi'
    echohl None
    return
  endif

  " Mirror s:StopJob()'s s:StopDrain(): every (re)started job needs the drain
  " timer live to process its events. On the parked-resume path s:OpenWindow()
  " returns before s:BufSetup() (the other StartDrain call site), so without
  " this the drain stays stopped and agent_start never arrives — the chat sits
  " at "contacting pi" and replies never render.
  call s:StartDrain()

  " Ask pi for its live state; the get_state response carries the current
  " model, which PiChatStatusModel() renders on the right of the statusline.
  call s:Send({'type': 'get_state'})

  if s:fresh
    call s:AddLogLines(['', 'pi chat — <CR> sends · <C-CR> newline · <C-c> abort'])
    if !empty(g:pi_chat_master_prompt)
      call s:AddLogLines(['📋 master prompt: ' . (filereadable(expand(g:pi_chat_master_prompt, 1))
            \ ? fnamemodify(expand(g:pi_chat_master_prompt, 1), ':p')
            \ : '(inline ' . strlen(g:pi_chat_master_prompt) . ' chars)')])
    endif
    if s:resumed_kind ==# 'file' || s:resumed_kind ==# 'dir'
      let l:what = s:resumed_kind ==# 'file' ? 'this file''s' : 'this folder''s'
      call s:AddLogLines(['↻ resumed ' . l:what . ' pi session'])
      let l:prior = s:LoadSessionTranscript(s:session_id)
      if !empty(l:prior)
        call s:AddLogLines(l:prior)
      endif
      " Resume the thinking panel the same way: re-read the session's thinking
      " so :PiThinking shows prior turns (rendered on open via the flush).
      let l:think = s:LoadSessionThinking(s:session_id)
      if !empty(l:think)
        let s:think_text = join(l:think, "\n") . "\n"
        let s:think_frag = ''
        let s:think_lines = 0
        let s:think_synced = 0
        let s:think_pending = []
        let s:think_synced_text = s:think_text
        let s:think_dirty = 0
        call s:ThinkRenderFull()
      endif
    endif
    call s:SetLine(s:NLines() + 1, '❯ ')
    let s:input_line = s:NLines()
  else
    " Resuming: keep the (possibly multi-line, half-typed) prompt block.
    if s:input_line < 1 || s:input_line > s:NLines()
      let s:input_line = s:NLines()
    endif
    if s:Line(s:input_line) !~# '^❯'
      call s:SetLine(s:input_line, '❯ ')
    endif
  endif
  call s:CaptureTranscript()
  if !l:quiet
    call s:GotoInputInsert()
  endif
endfunction

function! s:StopJob()
  call s:StopDrain()
  if s:HasJob()
    try
      call pi_chat_compat#ChClose(s:job)
    catch
    endtry
    try
      call pi_chat_compat#JobStop(s:job)
    catch
    endtry
    let s:job = v:null
  endif
  call s:BusyStop()
  let s:running = 0
  let s:queue = []
  let s:tools = {}
  let s:tail = ''
  let s:tail_line = 0
endfunction

" ------------------------------ user commands ------------------------------

function! s:PiAbort()
  call s:Send({'type': 'abort'})
  call s:BusyStop()
  call s:AddLogLines(['', '⚠ abort requested'])
  call s:HideWorking()
  call s:SetStatus('aborted')
endfunction

" Fires on every BufEnter, and is also called directly by s:PanelGuard after
" it moves a file buffer out of a panel window (buffer switches made inside a
" BufEnter autocmd do not reliably fire new BufEnter events, so the swap
" drives this call itself).
"
" React only when a:buf is a real file (not chat, thinking panel, or any
" virtual buffer) and differs from the current context file: re-key the
" context file and, when the agent is running, log the switch in the chat.
" pi is NOT sent a prompt of its own - that would cost a full model turn on
" every :e / :b / quickfix jump - it is told with the user's next prompt,
" which then opens with 'I switched the file I am working on to: ...'
" (s:switch_pending).
function! s:FileSwitch(buf) abort
  if !g:pi_chat_track_files
    return
  endif
  if a:buf <= 0 || a:buf == s:buf || a:buf == s:think_buf
    return
  endif
  " An unnamed buffer is never a context file.  (bufname is checked directly
  " because fnamemodify('', ':p') expands to the working directory.)
  if empty(bufname(a:buf))
    return
  endif
  let l:fn = fnamemodify(bufname(a:buf), ':p')
  if !empty(getbufvar(a:buf, '&buftype'))
    return
  endif
  " The chat buffers may not have buftype=nofile set yet when BufEnter
  " fires on their creation, so match their names as well.
  if bufname(a:buf) =~# '^__PiChat'
    return
  endif
  " The same buffer can surface with different path spellings (e.g. /tmp vs
  " /private/tmp), so compare buffer numbers, not just path strings.
  if l:fn ==# s:context_file || a:buf == s:context_buf
    return
  endif
  let s:context_file = l:fn
  let s:context_buf = a:buf
  let s:switch_pending = 1
  if !s:JobAlive()
    return
  endif
  call s:WithChatWin(function('s:FileSwitchLog', [l:fn]))
endfunction

function! s:OnFileEnter() abort
  call s:FileSwitch(bufnr('%'))
endfunction

" Keeps the panels in their own windows.  If the cursor happens to sit on
" the chat or thinking panel and the user runs a buffer-switching command
" (:e file, :b, :bn, the buffer list, ...), the file buffer takes over the
" panel's window.  The panel buffer is bufhidden=hide, so it survives; put
" the file into the last real-file window and restore the panel in place,
" as if the command had been typed in the file window.  Without a live
" file window the file simply stays where the user put it (:PiOpen brings
" the panel back).
function! s:PanelGuard() abort
  let l:wid = win_getid()
  let l:bn = bufnr('%')
  " Panel buffers may lack buftype=nofile for one tick on creation, so the
  " name is the reliable test.
  if bufname('%') =~# '^__PiChat'
    let s:panel_wins[l:wid] = l:bn
    return
  endif
  if !empty(getbufvar('%', '&buftype'))
    return
  endif
  " A real file buffer just entered window l:wid.
  if !has_key(s:panel_wins, l:wid)
    let s:file_win = l:wid
    return
  endif
  let l:panel = s:panel_wins[l:wid]
  unlet s:panel_wins[l:wid]
  if !bufexists(l:panel) || getbufvar(l:panel, '&bufhidden') !=# 'hide'
    return
  endif
  if s:file_win ==# l:wid || s:file_win == 0 || win_id2win(s:file_win) == -1
    let s:file_win = l:wid
    return
  endif
  " Restore the panel in its own window (we are still in l:wid) ...
  execute 'silent buffer ' . l:panel
  " ... then show the file in the user's file window.  This order matters:
  " the file's BufEnter triggers the context-switch log, which must land in
  " the chat window, not in the file window.
  call win_gotoid(s:file_win)
  execute 'silent buffer ' . l:bn
  " Stay where the user's cursor was (the panel window).
  call win_gotoid(l:wid)
  " The swap happened inside the file's BufEnter, whose autocmd chain sees
  " the panel buffer again (and nested :buffer calls do not reliably refire
  " BufEnter): drive the context switch ourselves so the log lands in the
  " restored panel and pi is told about the file.
  call s:FileSwitch(l:bn)
endfunction

" Runs with the chat window current; keep it side-effect-free apart from the
" log line (s:WithChatWin runs the closure synchronously).
function! s:FileSwitchLog(name) abort
  call s:AddLogLines(['', 'pi-chat: context file switched: ' . a:name
        \ . ' (pi is told with your next prompt)'])
endfunction

function! s:PiFile(path)
  if a:path ==# ''
    if s:context_file ==# ''
      echo 'pi-chat: no context file (view a file before :PiOpen, or :PiFile <path>)'
    else
      echo 'pi-chat context file: ' . s:context_file
    endif
    return
  endif
  let l:f = fnamemodify(a:path, ':p')
  if !filereadable(l:f) && !isdirectory(fnamemodify(l:f, ':h'))
    echohl ErrorMsg
    echomsg 'pi-chat: no such file or directory: ' . l:f
    echohl None
    return
  endif
  let s:context_file = l:f
  let s:context_buf = bufnr(l:f)
  call s:AddLogLines(['pi-chat: context file: ' . l:f
        \ . (s:JobAlive() ? ' (cwd applies when the agent restarts: :PiRestart)' : '')])
endfunction

" Resolve a tool path the way pi does: relative paths are resolved against
" the directory of the file the chat was opened from (or the cwd if none).
function! s:AbsToolPath(path)
  if a:path[0] !=# '/' && a:path !~? '^[A-Za-z]:[/\\]'
    let l:base = (s:context_file !=# '' && isdirectory(fnamemodify(s:context_file, ':h')))
          \   ? fnamemodify(s:context_file, ':h')
          \   : getcwd()
    return fnamemodify(l:base . '/' . a:path, ':p')
  endif
  return fnamemodify(a:path, ':p')
endfunction

" pi's edit/write tool just wrote a file on disk. If that file is open in a
" buffer, pull the new content in so the user sees the change live. Relative
" paths resolve against pi's cwd (the context file's directory). Never clobbers
" a buffer holding unsaved local edits - that case is flagged instead.
function! s:ReloadFile(path, ...)
  if empty(a:path)
    return
  endif
  " Why the file changed: 'pi edited it' (edit/write tool, the default)
  " or 'changed on disk' (another tool, e.g. bash, rewrote it).
  let l:reason = a:0 ? a:1 : 'pi edited it'
  let l:fn = s:AbsToolPath(a:path)
  if !filereadable(l:fn)
    return
  endif
  let l:b = bufnr(l:fn)
  if l:b < 0
    " Not open in any buffer: nothing to reload.
    return
  endif
  " Don't clobber local edits the user made in this buffer.
  if getbufvar(l:b, '&modified')
    call s:Notify(fnamemodify(l:fn, ':t') . ' ' . l:reason
          \ . ' - you have unsaved changes; :e! to reload its content')
    return
  endif
  let l:new = readfile(l:fn)
  " Reload through Vim's own file-change check: with 'autoread' on for this
  " buffer, :checktime re-reads it from disk (shown or hidden, keeping the
  " cursor and undo history) AND records the new file timestamp.  Writing
  " the lines with setbufline() left that timestamp stale, so Vim still saw
  " "the file changed since reading it": W11 prompts on the next checktime
  " or focus, and a warning on :w.  The option goes back to following the
  " global value afterwards.
  let l:tick = getbufvar(l:b, 'changedtick')
  call setbufvar(l:b, '&autoread', 1)
  try
    execute 'silent! checktime ' . l:b
  finally
    call setbufvar(l:b, '&autoread', -1)
  endtry
  " (changedtick, not a line comparison: readfile() keeps the \r of a
  " 'fileformat=dos' file, the buffer does not.)
  if getbufvar(l:b, 'changedtick') == l:tick
        \ && getbufline(l:b, 1, '$') !=# (empty(l:new) ? [''] : l:new)
    " Not reloaded (e.g. a FileChangedShell autocmd of the user's declined
    " it): push the content in directly.  setbufline() with a List only
    " overwrites from line 1, so delete the old tail first.
    let l:old = len(getbufline(l:b, 1, '$'))
    if l:old > 1
      call deletebufline(l:b, 2, l:old)
    endif
    call setbufline(l:b, 1, empty(l:new) ? [''] : l:new)
    " setbufline() marks the buffer modified; it now matches disk.
    call setbufvar(l:b, '&modified', 0)
  endif
  call s:Notify('reloaded ' . fnamemodify(l:fn, ':t') . ' (' . l:reason . ')')
  " Force a repaint: the reloaded window is usually the one in the
  " background while the user sits in the chat panel, and vim may not
  " refresh its screen area until the next keystroke.  Without this the
  " new content lags behind the 'reloaded ...' notice by exactly that.
  redraw
endfunction

" Build a pi-style display diff (the same format the edit tool returns in
" result.details.diff, see pi edit-diff.js) for a whole-file replacement.
" O(n): common prefix/suffix lines are shown as context, everything between
" as removed + added.  Line format (unindented; s:DiffBlock adds the indent):
"   ' N text'  context (new-file line number)
"   '-N text'  removed (old-file line number)
"   '+N text'  added (new-file line number)
"   '    ...'  skipped run
function! s:DiffFormat(old, new)
  let l:no = len(a:old)
  let l:nn = len(a:new)
  let l:ctx = 4
  let l:w = len(string(l:no > l:nn ? l:no : l:nn))
  " Common prefix.
  let l:p = 0
  while l:p < l:no && l:p < l:nn && a:old[l:p] ==# a:new[l:p]
    let l:p += 1
  endwhile
  " Common suffix (kept away from the prefix).
  let l:s = 0
  while l:s < l:no - l:p && l:s < l:nn - l:p
        \ && a:old[l:no - 1 - l:s] ==# a:new[l:nn - 1 - l:s]
    let l:s += 1
  endwhile
  let l:del = (l:no - l:s > l:p) ? a:old[l:p : l:no - l:s - 1] : []
  let l:add = (l:nn - l:s > l:p) ? a:new[l:p : l:nn - l:s - 1] : []
  if empty(l:del) && empty(l:add)
    return []
  endif
  let l:out = []
  " Head context: the last l:ctx lines of the common prefix (new numbering).
  let l:h0 = (l:p > l:ctx) ? l:p - l:ctx : 0
  if l:h0 > 0
    call add(l:out, ' ' . printf('%*s', l:w, '') . ' ...')
  endif
  for l:i in range(l:h0, l:p - 1)
    call add(l:out, ' ' . printf('%*s', l:w, l:i + 1) . ' ' . a:new[l:i])
  endfor
  " Removed lines (old numbering), then added lines (new numbering).
  for l:i in range(l:p, l:no - l:s - 1)
    call add(l:out, '-' . printf('%*s', l:w, l:i + 1) . ' ' . a:old[l:i])
  endfor
  let l:num = l:p + 1
  for l:i in range(l:p, l:nn - l:s - 1)
    call add(l:out, '+' . printf('%*s', l:w, l:num) . ' ' . a:new[l:i])
    let l:num += 1
  endfor
  " Tail context: the first l:ctx lines of the common suffix (new numbering).
  for l:i in range(0, min([l:ctx, l:s]) - 1)
    call add(l:out, ' ' . printf('%*s', l:w, l:num) . ' ' . a:new[l:nn - l:s + l:i])
    let l:num += 1
  endfor
  if l:s > l:ctx
    call add(l:out, ' ' . printf('%*s', l:w, '') . ' ...')
  endif
  return l:out
endfunction

" Indent a diff block for the log buffer, capping it at
" g:pi_chat_tool_diff_max lines with a trailing notice.
function! s:DiffBlock(lines)
  let l:max = get(g:, 'pi_chat_tool_diff_max', 200)
  let l:cut = l:max > 0 && len(a:lines) > l:max
  let l:out = map(copy(l:cut ? a:lines[:l:max - 1] : a:lines), '"  " . v:val')
  if l:cut
    call add(l:out, '  … ' . (len(a:lines) - l:max) . ' more lines')
  endif
  return l:out
endfunction

" Diff preview for the write tool: pi does not compute one for writes, so
" diff the current on-disk content against the incoming content and format
" it like pi's edit diff.  At tool start the on-disk file still holds the
" pre-write content, which is exactly what we want.
function! s:WriteDiff(path, content)
  let l:new = split(a:content, "\n", 1)
  if !empty(l:new) && l:new[-1] ==# ''
    let l:new = l:new[:-2]
  endif
  let l:old = []
  if a:path !=# ''
    let l:fn = s:AbsToolPath(a:path)
    if filereadable(l:fn) && !isdirectory(l:fn) && getfsize(l:fn) < 2 * 1024 * 1024
      let l:old = readfile(l:fn)
    endif
  endif
  let l:block = s:DiffBlock(s:DiffFormat(l:old, l:new))
  if !empty(l:block)
    call s:AddLogLines(l:block)
  endif
endfunction

" Before we tell pi to work on the context file, make sure the buffer we'll
" show it is up to date. If it has unsaved local edits they would be
" overwritten the moment pi's edit/write tool hits disk (s:ReloadFile warns
" and does not clobber a modified buffer). With g:pi_chat_autosave_context
" the save is silent; otherwise ask first.
function! s:EnsureContextSaved()
  if !g:pi_chat_context_file
    return
  endif
  let l:ctx = s:context_file
  if empty(l:ctx)
    let l:ctx = expand('#:p')
  endif
  if empty(l:ctx)
    return
  endif
  let l:b = bufnr(l:ctx)
  if l:b < 0 || !getbufvar(l:b, '&modified')
    return
  endif
  let l:name = fnamemodify(l:ctx, ':t')
  if g:pi_chat_autosave_context
    if s:SaveBuffer(l:b)
      call s:Notify(l:name . ' saved so pi edits the latest version')
    else
      call s:Notify('could not save ' . l:name . '; pi may edit an out-of-date copy', 'warning')
    endif
  else
    let l:ans = inputlist(['pi will edit ' . l:name . '.  Save your changes first?',
          \ '1. Yes, save my changes',
          \ '2. No, let pi edit the on-disk version'])
    if l:ans == 1
      if s:SaveBuffer(l:b)
        call s:Notify(l:name . ' saved so pi edits the latest version')
      else
        call s:Notify('could not save ' . l:name . '; pi may edit an out-of-date copy', 'warning')
      endif
    else
      call s:Notify(l:name . ' left unsaved; pi edits the on-disk version', 'warning')
    endif
  endif
endfunction

" Write buffer a:b to its file without disturbing the windows (saves the
" alternate window's file from the chat). Returns 1 on success.
function! s:SaveBuffer(b)
  if !bufloaded(a:b)
    return 0
  endif
  if bufwinid(a:b) >= 0 && exists('*win_execute')
    " Run :write in the buffer's window without switching to it.
    call win_execute(bufwinid(a:b), 'silent! write')
    return !getbufvar(a:b, '&modified')
  endif
  " Fallback: briefly switch to the buffer, write, and come back.
  let l:cur = bufnr('')
  execute 'silent! buffer ' . a:b
  silent! write
  execute 'silent! buffer ' . l:cur
  return !getbufvar(a:b, '&modified')
endfunction

function! s:PiClear()
  " Drop any in-flight working line first so the wipe below sees a clean, correct
  " input_line (a live ⏳ line above the prompt would otherwise be wiped without
  " decrementing the tracked line numbers).
  call s:HideWorking()
  " The new session has no thinking yet, so clear the thinking panel along
  " with the transcript (otherwise the old session's thoughts linger).
  call s:ThinkReset()
  " Restart the agent process for a brand-new session instead of sending pi
  " an in-process `new_session` command: replacing the session invalidates
  " the context objects that loaded extensions keep, and
  " pi-observational-memory then throws "stale ctx" in
  " maybeTriggerCompaction on the next settled turn and exits the agent with
  " code 1 (see the s:clear_new_session note in s:StartJob).  A fresh process
  " has a fresh context, and a process restart is already how :PiOpen picks a
  " parked session back up.  s:fresh stays 0: keep the prompt line (and any
  " half-typed text) instead of re-emitting the fresh-session hint.
  call s:StopJob()
  let s:clear_new_session = 1
  let s:fresh = 0
  call s:StartJob()
  " Wipe the transcript above the input line and record the reset in the log
  " (s:input_line points at the prompt line now, so the wipe runs after
  " s:StartJob has re-pointed it).
  if s:buf > 0 && buflisted(s:buf) && s:input_line > 1
    call s:WithChatWin(function('s:WipeTranscript'))
  endif
  call s:SetStatus('new session')
endfunction

" Delete the whole log above the prompt block (not blank it: overwriting
" with '' left one empty line per old transcript line at the top).
function! s:WipeTranscript()
  if s:input_line - 1 > s:NLines()
    return
  endif
  call deletebufline(s:buf, 1, s:input_line - 1)
  let s:input_line = 1
  let s:tail = ''
  let s:tail_line = 0
  call s:CaptureTranscript()
  call s:AddLogLines(['pi chat: new session', ''])
endfunction

function! s:PiRestart()
  " Restart the pi process in place and resume the SAME session: the session
  " JSONL and the on-screen transcript are kept, only the process state is
  " rebuilt.  Use after changing g:pi_chat_args (or pi's own config /
  " extensions) without losing the conversation, and as recovery for a wedged
  " or already-exited process (a dead s:job is fine: stopping it is a no-op).
  " s:clear_new_session stays 0, so StartJob's create-or-resume picks the id
  " back up instead of wiping it; s:fresh stays 0, so the transcript and any
  " half-typed prompt are preserved.  Note: this does NOT re-read this
  " plugin's vimscript — restart vim for that.
  if s:buf < 1
    echohl WarningMsg
    echomsg 'pi chat: no chat open (use :PiOpen)'
    echohl None
    return
  endif
  call s:StopJob()
  let s:clear_new_session = 0
  let s:fresh = 0
  call s:StartJob()
  call s:AddLogLines(['↻ pi process restarted (session resumed)'])
endfunction

function! s:PiClose()
  call s:ThinkCloseAll()
  let l:buf = s:buf
  call s:StopJob()
  let s:buf = -1
  let s:input_line = 0
  let s:tail_line = 0
  let s:tail = ''
  if s:park_timer != -1
    call timer_stop(s:park_timer)
    let s:park_timer = -1
  endif
  let s:transcript = []
  let s:guarding = 0
  let s:pinning = 0
  if l:buf > 0 && buflisted(l:buf)
    execute 'silent! bdelete! ' . l:buf
  endif
endfunction

" The chat buffer entered a window: showing a parked chat resumes its agent.
" Skipped while s:StartJob() itself is opening the window (it starts the
" job right after), which would otherwise launch pi twice.
function! s:ChatWinGained()
  if s:starting
    return
  endif
  if !s:JobAlive() && s:buf > 0 && buflisted(s:buf)
    " Resuming a parked session.
    let s:fresh = 0
    call s:StartJob()
    call s:GotoInputInsert()
  endif
endfunction

" The chat buffer left a window.  Hiding it from every window parks the
" agent (the buffer and transcript survive, bufhidden=hide keeps them
" alive).  The check is deferred to a 0ms timer and asks win_findbuf()
" rather than keeping a window counter: BufWinLeave does not fire while the
" buffer is still visible elsewhere (so a counter drifts), and a transient
" swap - s:PanelGuard putting the panel straight back, `:close | PiOpen` -
" must not stop and restart the agent.
function! s:ChatWinLost()
  if s:park_timer == -1
    let s:park_timer = timer_start(0, function('s:ParkIfHidden'))
  endif
endfunction

function! s:ParkIfHidden(...)
  let s:park_timer = -1
  if s:buf < 1 || !buflisted(s:buf) || !empty(win_findbuf(s:buf))
    return
  endif
  if s:JobAlive()
    " Park: stop the agent, but keep the transcript so :PiOpen / :b
    " __PiChat__ resumes the same conversation.
    call s:StopJob()
    echo 'pi chat: agent parked — :PiOpen resumes it'
  endif
endfunction

" --------------------------------- window ----------------------------------

" Size for the chat window: an integer is an absolute column/row count;
" a float between 0 and 1 is a fraction of &columns (vertical split) or
" &lines (horizontal), computed when the window opens.
function! s:ChatDim(vertical)
  if type(g:pi_chat_width) == type(0.0) && g:pi_chat_width > 0 && g:pi_chat_width < 1
    let l:total = a:vertical ? &columns : &lines
    if l:total > 3
      let l:dim = round(g:pi_chat_width * l:total)
      if l:dim >= 2
        return l:dim
      endif
    endif
  endif
  return g:pi_chat_width
endfunction

function! s:OpenWindow()
  if s:buf > 0 && buflisted(s:buf)
    if s:FindWin() > 0
      " Already showing in a window: just focus it.
      call s:JumpToBuf()
      return
    endif
    " Parked: the buffer is alive but has no window. Re-open it in a fresh
    " right-hand split (restoring its size) instead of taking over whatever
    " window the user is currently in.
    if g:pi_chat_split ==# 'new'
      execute 'silent new'
    else
      execute 'silent botright ' . g:pi_chat_split
      if g:pi_chat_split ==# 'vsplit'
        execute 'silent vertical resize ' . s:ChatDim(1)
      else
        execute 'silent resize ' . s:ChatDim(0)
      endif
    endif
    execute 'silent buffer ' . s:buf
    return
  endif
  if g:pi_chat_split !~# '^vsplit$\|^split$\|^new$'
    let g:pi_chat_split = 'vsplit'
  endif
  " :new takes no window-size argument, so handle it separately.
  if g:pi_chat_split ==# 'new'
    execute 'silent new ' . s:bufname
  else
    " Split first, then size the new (current) window. The size argument on
    " :vsplit/:split is unreliable when 'equalalways' is on (it re-equalizes
    " the windows and discards the count), so resize explicitly afterwards.
    execute 'silent botright ' . g:pi_chat_split . ' ' . s:bufname
    if g:pi_chat_split ==# 'vsplit'
      execute 'silent vertical resize ' . s:ChatDim(1)
    else
      execute 'silent resize ' . s:ChatDim(0)
    endif
  endif
  let s:buf = bufnr('%')
  call s:BufSetup()
endfunction

" Called from the buffer-local <CR> map in insert mode.
function! PiChatSendInput()
  if s:buf < 1 || !buflisted(s:buf) || s:input_line < 1
    return
  endif
  " The input block is the prompt line plus whatever continuation lines the
  " user opened below it (up to the last line).
  let l:lines = getbufline(s:buf, s:input_line, '$')
  if empty(l:lines)
    return
  endif
  if l:lines[0] =~# '^❯\s*$'
    let l:lines[0] = ''
  else
    let l:lines[0] = substitute(l:lines[0], '^❯\s\?', '', '')
  endif
  let l:text = join(l:lines, "\n")
  if l:text ==# ''
    return
  endif
  " Drop the rest of the block; the prompt line itself becomes a fresh ❯.
  call s:DeleteLines(s:input_line + 1, s:NLines())
  call s:SetLine(s:input_line, '❯ ')
  call s:UserPrompt(l:text)
  call s:GotoInputInsert()
endfunction

" Open a continuation line below the cursor and stay in insert mode on it.
" (Used by the <C-CR> mapping so the user can type a multi-line prompt.)
function! s:PiChatNewline()
  call append(line('.'), '')
  call cursor(line('.') + 1, 1)
  startinsert
endfunction

function! PiChatAbort()
  call s:PiAbort()
  call s:GotoInput()
  startinsert
endfunction

function! s:BufSetup()
  setlocal buftype=nofile bufhidden=hide noswapfile nonumber norelativenumber nospell
  setlocal wrap linebreak cursorline foldcolumn=0
  " '%=' floats everything after it to the right, so the model label sits at
  " the right edge next to the status text ('pi chat' / 'pi is working').
  setlocal statusline=%<%{PiChatStatusText()}%=%{PiChatStatusModel()}

  syn match PiChatUser    '^❯.*'
  syn match PiChatTool    '^  ⚙.*'
  syn match PiChatToolEnd '^  [✓✗].*'
  syn match PiChatSys     '^[┌└│┐┘─].*\|^─\+.*'
  syn match PiChatWarn    '^⚠.*\|  ⚠.*\|⏱.*'
  syn match PiChatWorking '^⏳.*'
  syn match PiChatNoticeInfo  '^ℹ.*\|  ℹ.*'
  syn match PiChatNoticeError '^⛔.*\|  ⛔.*'
  syn match PiChatHint    '^pi chat —.*'
  hi def link PiChatUser        Comment
  hi def link PiChatTool        Function
  hi def link PiChatToolEnd     Function
  hi def link PiChatSys         NonText
  hi def link PiChatWarn        WarningMsg
  hi def link PiChatWorking     Comment
  hi def link PiChatNoticeInfo  Comment
  hi def link PiChatNoticeError ErrorMsg
  hi def link PiChatHint        NonText
  " Diff previews for file tools (s:DiffFormat / pi's edit-diff format; see
  " s:WriteDiff and the tool_execution_end handler).  Defined after the
  " markdown rules below so they win per byte on the +/− prefixes.
  syn match PiChatDiffAdd  '^  +.*'
  syn match PiChatDiffDel  '^  -.*'
  syn match PiChatDiffCtx  '^ \{2}\s\+\d\+\(\s.*\)\?\|^  \d\+\s*$\|^ \{2}\s\+\.\.\.\s*$'
  syn match PiChatDiffMore '^  ….*'
  syn match PiChatToolOut  '^    │.*'
  hi def link PiChatDiffAdd  DiffAdd
  hi def link PiChatDiffDel  DiffDelete
  hi def link PiChatDiffCtx  NonText
  hi def link PiChatDiffMore NonText
  hi def link PiChatToolOut  Comment
  call s:ApplyMarkdown()

  " The transcript stays modifiable (programmatic :append/setline fail under
  " nomodifiable) but is reverted by s:GuardTranscript on any interactive edit;
  " only the ❯ prompt block at the bottom takes typing.
  inoremap <buffer> <silent> <CR> <C-o>:call PiChatSendInput()<CR>
  inoremap <buffer> <silent> <C-CR> <Esc>:call s:PiChatNewline()<CR>
  inoremap <buffer> <silent> <C-c> <C-o>:call PiChatAbort()<CR>
  " Jump to the input line (an ex command in normal mode — <C-o> would not
  " work there), then run the original normal-mode command.
  nnoremap <buffer> <silent> A :call s:GotoInput()<CR>A
  nnoremap <buffer> <silent> i :call s:GotoInput()<CR>i

  augroup PiChatBuf
    autocmd!
    " Revert any user edit to the transcript (this build has no :textlock).
    autocmd TextChanged,TextChangedI <buffer> call s:GuardTranscript()
    " Keep the ❯ prompt marker undeletable and uneditable-before.
    autocmd TextChangedI,CursorMovedI <buffer> call s:PinInputCursor()
    " Ignore typing on the prompt while pi is generating a turn.
    autocmd TextChangedI <buffer> call s:GuardBusyInput()
    " Window count drives parking/resuming the agent.
    autocmd BufWinEnter <buffer> call s:ChatWinGained()
    autocmd BufWinLeave <buffer> call s:ChatWinLost()
  augroup END

  let s:input_line = line('$')
  let s:tail_line = 0
  call s:StartDrain()
endfunction

" --------------------------------- output ----------------------------------

" Depending on the Vim build the out/err callback may deliver the lines as a
" List, as a single String, or as one chunk containing several newline
" separated lines. Normalize to a plain List of lines here.
function! s:QueueLines(items, prefix)
  let l:items = a:items
  if type(l:items) == v:t_string
    let l:items = [l:items]
  endif
  for l:line in l:items
    for l:part in split(l:line, '\r\?\n')
      if !empty(l:part)
        call add(s:queue, a:prefix . l:part)
      endif
    endfor
  endfor
endfunction

function! s:OnOut(ch, lines)
  call s:QueueLines(a:lines, '')
endfunction

function! s:OnErr(ch, lines)
  " pi logs "Warning: No project session found with id ..." whenever --session-id
  " names a session that does not exist yet; that is our intended
  " create-if-missing path, not an error, so swallow that line.
  let l:warn = 'No project session found with id'
  if type(a:lines) == v:t_list
    let l:lines = filter(copy(a:lines), 'v:val !~# l:warn')
  elseif a:lines =~# l:warn
    let l:lines = []
  else
    let l:lines = a:lines
  endif
  call s:QueueLines(l:lines, '⚠ ')
endfunction

function! s:OnExit(job, code)
  " Ignore the exit of a job we are no longer tracking: :PiClear/:PiRestart
  " restart the process synchronously and parking/:PiClose stop it on
  " purpose, so the old process's exit can arrive after s:job was cleared or
  " replaced (s:StopJob() below would then kill the live one).  exit_cb gets
  " the Job itself; compare process ids (a Job/Channel `!=` is always true).
  if !s:HasJob() || s:JobPid(s:job) != s:JobPid(a:job)
    return
  endif
  let l:was_alive = s:JobAlive()
  let l:code = a:code
  call s:StopJob()
  " Commit the tail and any exit warning with the chat window current (they
  " address it by line number); this callback can fire while the user is in
  " another window, e.g. reading the thinking panel.
  call s:WithChatWin({ -> s:OnExitFinish(l:was_alive, l:code) })
  call s:BusyStop()
  call s:SetStatus('agent stopped')
  echohl WarningMsg
  echomsg 'pi-chat: agent process stopped (code ' . l:code . ')'
  echohl None
endfunction

function! s:JobPid(job)
  return pi_chat_compat#JobPid(a:job)
endfunction

function! s:OnExitFinish(was_alive, code)
  call s:CommitTail()
  " A process that died mid-turn never sends agent_settled: drop the
  " working line and put the ❯ prompt back.
  call s:HideWorking()
  if !a:was_alive && a:code != 0
    call s:AddLogLines(['', '⚠ pi exited with code ' . a:code])
  endif
endfunction

" Line-buffered drain: the out callback only queues; a repeating timer
" applies the queued lines so we never mutate the buffer from a job
" callback mid-update.
function! s:StartDrain()
  if empty(s:drain_timer)
    let s:drain_timer = timer_start(50, function('s:DrainTick'), {'repeat': -1})
  endif
endfunction

function! s:StopDrain()
  if !empty(s:drain_timer)
    call timer_stop(s:drain_timer)
    let s:drain_timer = ''
  endif
endfunction

function! s:DrainTick(timer)
  " An idle tick (no queued events, not busy) edits nothing, so it must not
  " hop windows: hopping to the chat window and back every 50ms while the
  " user sits in the thinking panel (or any other window) is a perpetual
  " cursor-jump redraw storm that pegs GPU-accelerated terminals at 100%.
  if empty(s:queue) && !s:busy
    return
  endif
  " A busy tick with nothing queued only advances the spinner, which edits
  " no buffer text (status via setbufvar): skip the hop entirely, or a long
  " turn spends its whole duration hopping windows 20 times a second.
  if empty(s:queue)
    call s:SpinnerTick()
    return
  endif
  " Run the entire tick with the chat window current (see s:WithChatWin): the
  " queued events and the spinner both edit the chat buffer by line number, so
  " they must not run while the user is in the thinking panel or elsewhere.
  call s:WithChatWin(function('s:DrainTickBody'))
endfunction

function! s:DrainTickBody()
  call s:DrainQueue()
  call s:SpinnerTick()
endfunction

function! s:SpinnerTick()
  if s:busy
    let s:spin = (s:spin + 1) % len(s:spin_frames)
    call s:SpinnerUpdate()
  endif
endfunction

function! s:DrainQueue()
  if empty(s:queue)
    return
  endif
  let l:lines = s:queue
  let s:queue = []

  let l:sticky = 1
  if s:buf > 0 && buflisted(s:buf) && s:input_line > 0
    let l:sticky = s:CursorOnInputLine()
  endif

  for l:line in l:lines
    if empty(l:line)
      continue
    endif
    try
      let l:msg = json_decode(l:line)
    catch
      call s:AddLogLines(['  ' . l:line])
      continue
    endtry
    call s:HandleEvent(l:msg)
  endfor

  " Flush the thinking panel once per tick: the deltas were only
  " accumulated during the pass above, so this is one buffer write no
  " matter how many deltas arrived.
  call s:ThinkFlush()

  if l:sticky
    call s:StickToInput()
  endif
endfunction

" The drain timer runs in the background, so the "user is typing" check must
" only apply while the chat window is in the foreground — otherwise
" DrainQueue would yank the user back to the chat window every tick.
function! s:CursorOnInputLine()
  if s:buf < 1 || !buflisted(s:buf) || s:input_line < 1
    return 0
  endif
  let l:win = s:FindWin()
  if l:win < 1
    return 0
  endif
  return win_getid() == l:win && line('.') >= s:input_line
endfunction

" Re-anchor the user's cursor after the drain tick edited the log region
" while the cursor sat on the prompt block. Inserting lines ABOVE the cursor
" shifts it automatically, so the common case needs nothing at all — and
" s:GotoInput() must not run here: it would reset the column to just past
" the ❯, yanking the cursor back to the start of the line mid-sentence on
" every notification or tool line that lands while the user is typing.
" Correct the cursor only when it was actually displaced:
"  - it sat in the log region (its line got absorbed) -> back to the prompt;
"  - it sits on the prompt line in front of the ❯ marker -> behind it.
" The second case is what a finished turn leaves behind: the glyph is blanked
" while pi works (the cursor clamps to byte col 1) and s:HideWorking() puts
" the '❯ ' prefix back, but nothing else ever moves a col-1 cursor —
" s:PinInputCursor only fires in insert mode, and the turn ends while the
" user is in normal mode. The user can never intend to rest in front of the
" marker (s:PinInputCursor forbids it), so re-anchoring is always safe.
function! s:StickToInput()
  if s:buf < 1 || !buflisted(s:buf) || s:input_line < 1
    return
  endif
  let l:win = s:FindWin()
  if l:win < 1 || win_getid() != l:win
    return
  endif
  if line('.') < s:input_line
    call cursor(s:input_line, s:InputCol(s:input_line))
    return
  endif
  if line('.') == s:input_line
    let l:min = s:InputCol(s:input_line)
    if col('.') < l:min
      call cursor(s:input_line, l:min)
    endif
  endif
endfunction

" Appends log lines above the input line (and above the tail line when a
" streaming fragment is in progress).
function! s:AddLogLines(lines)
  if s:buf < 1 || !buflisted(s:buf) || empty(a:lines) || s:input_line < 1
    return
  endif
  " A single string holding embedded newlines would be collapsed onto one
  " buffer line on store, so expand each element into one line per source
  " line. keepempty=1 so intentional blank lines (and the blank separator
  " passed in as '') survive.
  let l:flat = []
  for l:item in a:lines
    call extend(l:flat, split(l:item, "\n", 1))
  endfor
  if empty(l:flat)
    return
  endif
  " Collapse blank-line runs to a single blank line: model text routinely
  " ends in a trailing \n (sometimes \n\n) and multi-line payloads (notifies,
  " resumed transcripts) carry their own blanks, so without this a
  " reply-to-tool gap balloons to several empty lines. A lone trailing blank
  " (the turn separator) survives.
  let l:clean = []
  for l:line in l:flat
    if l:line ==# '' && !empty(l:clean) && l:clean[-1] ==# ''
      continue
    endif
    call add(l:clean, l:line)
  endfor
  " If the line the block would land right below is already blank, drop
  " leading blanks too (they would just extend the same separator).
  let l:at = s:tail_line > 0 ? s:tail_line - 1 : s:input_line - 1
  if l:at >= 1 && s:Line(l:at) ==# ''
    while !empty(l:clean) && l:clean[0] ==# ''
      call remove(l:clean, 0)
    endwhile
  endif
  if empty(l:clean)
    return
  endif
  " Keep s:transcript in sync with the buffer edit above instead of a full
  " re-capture: the lines land after buffer line l:at (the line above the
  " streaming tail, or the last transcript line), so splice the list in
  " place - O(tail region), not O(n).
  let l:n = len(l:clean)
  if s:tail_line > 0
    call s:AppendLines(s:tail_line - 1, l:clean)
    let s:input_line += l:n
    let s:tail_line += l:n
    call extend(s:transcript, l:clean, l:at)
  else
    call s:AppendLines(s:input_line - 1, l:clean)
    let s:input_line += l:n
    let s:transcript += l:clean
  endif
endfunction

" --------------------------------- streaming --------------------------------

function! s:FlushTail()
  if s:tail ==# ''
    if s:tail_line > 0
      call s:SetLine(s:tail_line, '')
      let s:transcript[s:tail_line - 1] = ''
    endif
    return
  endif
  let l:pos = s:tail
  let l:lines = []
  let l:nl = stridx(l:pos, "\n")
  while l:nl >= 0
    " strpart, not l:pos[:l:nl - 1]: at l:nl == 0 that slice is [:-1], the
    " WHOLE string, which re-emitted the text after a leading newline.
    call add(l:lines, strpart(l:pos, 0, l:nl))
    let l:pos = l:pos[l:nl + 1 :]
    let l:nl = stridx(l:pos, "\n")
  endwhile
  if !empty(l:lines)
    call s:AddLogLines(l:lines)
  endif
  let s:tail = l:pos
  if s:tail_line > 0
    " AddLogLines above already spliced the transcript; the tail line itself
    " now holds s:tail.
    call s:SetLine(s:tail_line, s:tail)
    let s:transcript[s:tail_line - 1] = s:tail
  else
    " AddLogLines appends s:tail's line to the transcript; it becomes the new
    " streaming tail line.
    call s:AddLogLines([s:tail])
    let s:tail_line = s:input_line - 1
  endif
endfunction

function! s:CommitTail()
  if s:tail ==# '' && s:tail_line == 0
    return
  endif
  let l:rest = s:tail
  let l:had_line = s:tail_line
  let s:tail = ''
  let s:tail_line = 0
  if l:had_line > 0
    if s:Line(l:had_line) ==# ''
      " The message text ended in a newline: the tail line is just an empty
      " placeholder. If the line above it is already blank (the model's
      " trailing \n\n), drop the placeholder so the gap stays a single
      " separator line; otherwise the placeholder itself is the separator
      " and it stays.
      if l:had_line > 1 && s:Line(l:had_line - 1) ==# ''
        call s:DeleteLines(l:had_line, l:had_line)
        let s:input_line -= 1
        call remove(s:transcript, l:had_line - 1)
      endif
      return
    endif
    " The remainder already sits on the tail line; just end the turn.
    call s:AddLogLines([''])
  elseif l:rest ==# ''
    call s:AddLogLines([''])
  else
    " Fragment never materialized as a line; push it out, then separate.
    call s:AddLogLines([l:rest, ''])
  endif
endfunction

" -------------------------------- events -----------------------------------

function! s:HandleEvent(msg)
  let l:t = get(a:msg, 'type', '')
  if l:t ==# 'response'
    if get(a:msg, 'success', v:true) != v:true
      call s:AddLogLines(['', '⚠ ' . get(a:msg, 'error', 'command failed')])
      " A rejected prompt (no API key, bad model, ...) never starts a run, so
      " no agent_settled will ever clear the busy state: clear it here, or
      " the spinner runs forever and the input guard eats every keystroke.
      " A rejected follow-up while a run IS active leaves that run's state.
      if get(a:msg, 'command', '') ==# 'prompt' && !s:running
        call s:BusyStop()
        call s:HideWorking()
        call s:SetStatus('pi chat')
      endif
    else
      " Statusline model label: only set from pi-confirmed responses
      " (a failed set_model leaves it unchanged). Model changes are done
      " on the pi side (e.g. pi's own /model); this plugin only displays.
      let l:cmd = get(a:msg, 'command', '')
      let l:data = get(a:msg, 'data', {})
      if l:cmd ==# 'get_state' || l:cmd ==# 'set_model' || l:cmd ==# 'cycle_model'
        let l:m = s:ModelObject(l:data)
        if !empty(l:m)
          call s:SetModelLabel(s:ModelLabelOf(l:m))
        endif
      endif
    endif
    return
  endif

  if l:t ==# 'agent_start'
    let s:running = 1
    call s:SetStatus(' ● running')
  elseif l:t ==# 'agent_end'
    if get(a:msg, 'willRetry', v:false)
      call s:SetStatus(' ● retrying')
    endif
  elseif l:t ==# 'agent_settled'
    let s:running = 0
    call s:BusyStop()
    call s:CommitTail()
    call s:HideWorking()
    call s:SetStatus('pi chat')
  elseif l:t ==# 'message_update'
    call s:HandleDelta(a:msg)
  elseif l:t ==# 'message_end'
    call s:CommitTail()
  elseif l:t ==# 'tool_execution_start'
    let l:name = get(a:msg, 'toolName', 'tool')
    let l:args = get(a:msg, 'args', {})
    if type(l:args) != v:t_dict
      let l:args = {}
    endif
    " Remember which file this tool targets (to live-reload it on end) and
    " snapshot the context file, so tool_execution_end can detect a tool
    " other than edit/write (e.g. bash) rewriting it.
    let l:path = get(l:args, 'path', get(l:args, 'file_path', ''))
    let s:tools[s:ToolKey(a:msg)] = {
          \ 'path': type(l:path) == v:t_string ? l:path : '',
          \ 'stat': s:ContextStat()}
    let l:detail = ''
    if type(get(l:args, 'command', 0)) == v:t_string
      let l:detail = '  ⚙ ' . l:name . '  ' . l:args.command
    elseif type(get(l:args, 'path', 0)) == v:t_string
      let l:detail = '  ⚙ ' . l:name . '  ' . l:args.path
    else
      let l:detail = '  ⚙ ' . l:name
    endif
    call s:AddLogLines([l:detail])
    " write: the full new content is in the args, so preview the diff now
    " (pi does not compute one for writes).
    if l:name ==# 'write' && get(g:, 'pi_chat_tool_diff', 1)
          \ && type(get(l:args, 'path', 0)) == v:t_string
          \ && type(get(l:args, 'content', 0)) == v:t_string
          \ && l:args.content !=# ''
      call s:WriteDiff(l:args.path, l:args.content)
    endif
  elseif l:t ==# 'tool_execution_end'
    let l:tname = get(a:msg, 'toolName', 'tool')
    let l:key = s:ToolKey(a:msg)
    let l:tool = get(s:tools, l:key, {'path': '', 'stat': [-1, -1]})
    if has_key(s:tools, l:key)
      call remove(s:tools, l:key)
    endif
    if get(a:msg, 'isError', v:false)
      call s:AddLogLines(['  ✗ ' . get(a:msg, 'toolName', 'tool') . ' failed'])
      " The output of a failed tool is its error message: always show it.
      call s:AddLogLines(s:ToolOutput(get(a:msg, 'result', {})))
    else
      " pi hands us a ready-to-display diff for edits in result.details.diff
      " (same format as s:DiffFormat, so the same highlight rules apply).
      " Fake servers and older pi versions may not send it: just show the ✓.
      if l:tname ==# 'edit' && get(g:, 'pi_chat_tool_diff', 1)
        let l:res = get(a:msg, 'result', {})
        let l:d = (type(l:res) == v:t_dict) ? get(l:res, 'details', {}) : {}
        let l:diff = (type(l:d) == v:t_dict) ? get(l:d, 'diff', '') : ''
        if type(l:diff) == v:t_string && l:diff !=# ''
          let l:block = s:DiffBlock(split(l:diff, "\n", 1))
          if !empty(l:block)
            call s:AddLogLines(l:block)
          endif
        endif
      endif
      call s:AddLogLines(['  ✓ ' . l:tname])
      if index(['read', 'edit', 'write'], l:tname) < 0
        call s:AddLogLines(s:ToolOutput(get(a:msg, 'result', {})))
      endif
      " pi's edit/write tool just wrote a file: if it's open, reload it live.
      if l:tname ==# 'edit' || l:tname ==# 'write'
        call s:ReloadFile(l:tool.path)
      elseif l:tool.stat[0] >= 0 && s:ContextStat() !=# l:tool.stat
        " Some other tool (bash, ...) rewrote the context file on disk:
        " reload the open buffer the same way so it can't lag behind.
        call s:ReloadFile(s:context_file, 'changed on disk')
      endif
      " The context file's on-disk state is now what the buffer shows:
      " re-baseline the tools still in flight, so a parallel bash that ends
      " later does not report (and reload) this same change a second time.
      let l:now = s:ContextStat()
      for l:other in values(s:tools)
        let l:other.stat = l:now
      endfor
    endif
  elseif l:t ==# 'extension_ui_request'
    call s:UiRequest(a:msg)
  endif
endfunction

" A tool result's text (its 'text' content blocks, or a plain string) as
" indented '    │ ' lines, capped at g:pi_chat_tool_output lines with a
" '… N more lines' note.  [] when there is nothing to show or the option is 0.
function! s:ToolOutput(result)
  let l:max = get(g:, 'pi_chat_tool_output', 5)
  if type(l:max) != v:t_number || l:max <= 0
    return []
  endif
  let l:content = type(a:result) == v:t_dict ? get(a:result, 'content', '') : a:result
  let l:parts = []
  if type(l:content) == v:t_string
    call add(l:parts, l:content)
  elseif type(l:content) == v:t_list
    for l:block in l:content
      if type(l:block) == v:t_dict && get(l:block, 'type', '') ==# 'text'
            \ && type(get(l:block, 'text', 0)) == v:t_string
        call add(l:parts, l:block.text)
      endif
    endfor
  endif
  let l:lines = split(substitute(join(l:parts, "\n"), '\r', '', 'g'), "\n", 1)
  " Drop leading/trailing blank lines (commands routinely end in "\n").
  while !empty(l:lines) && l:lines[-1] =~# '^\s*$'
    call remove(l:lines, -1)
  endwhile
  while !empty(l:lines) && l:lines[0] =~# '^\s*$'
    call remove(l:lines, 0)
  endwhile
  if empty(l:lines)
    return []
  endif
  let l:out = map(l:lines[: l:max - 1], '"    │ " . v:val')
  if len(l:lines) > l:max
    call add(l:out, '    │ … ' . (len(l:lines) - l:max) . ' more lines')
  endif
  return l:out
endfunction

" Key of a tool call in s:tools: pi's toolCallId (servers without one share
" a single slot, i.e. the old one-tool-at-a-time behavior).
function! s:ToolKey(msg)
  let l:id = get(a:msg, 'toolCallId', '')
  return type(l:id) == v:t_string && l:id !=# '' ? l:id : '-'
endfunction

" [mtime, size] of the context file, or [-1, -1] when there is none.
function! s:ContextStat()
  return (s:context_file !=# '' && filereadable(s:context_file))
        \ ? [getftime(s:context_file), getfsize(s:context_file)] : [-1, -1]
endfunction

function! s:HandleDelta(msg)
  let l:evt = get(a:msg, 'assistantMessageEvent', {})
  if !has_key(l:evt, 'type')
    return
  endif
  if l:evt.type ==# 'text_delta'
    let s:tail .= get(l:evt, 'delta', '')
    call s:FlushTail()
  elseif l:evt.type ==# 'text_end'
    call s:CommitTail()
  elseif l:evt.type ==# 'thinking_delta'
    if g:pi_chat_show_thinking
      let s:tail .= get(l:evt, 'delta', '')
      call s:FlushTail()
    endif
    " the panel accumulates the stream even while hidden - or before it was
    " ever opened (s:think_buf == -1) - so opening it later still shows past
    " thoughts; s:ThinkAppendDelta keeps only the virtual string until the
    " buffer exists, then syncs incrementally (O(delta), not O(panel))
    call s:ThinkAppendDelta(get(l:evt, 'delta', ''))
  endif
endfunction

" ----------------------------- extension UI --------------------------------

" rpc-extension-ui.md: an extension_ui_request carries `method` plus
" method-specific top-level fields (title, message, options, placeholder,
" prefill).  Dialog methods (select/confirm/input/editor) block the
" extension until an extension_ui_response with the same `id` arrives:
" `value` (select/input/editor), `confirmed` (confirm) or `cancelled`.
" Fire-and-forget methods never get a reply.
"
" Dialogs run synchronously inside the drain tick, so a request's `timeout`
" cannot be enforced here (Vim runs no timers while a callback waits in a
" prompt); pi auto-resolves it on its side, and a late answer is ignored.
let s:ui_fire_and_forget = ['setWidget', 'setTitle']

function! s:UiRequest(req)
  let l:method = get(a:req, 'method', '')
  let l:label = get(a:req, 'title', get(a:req, 'message', 'pi chat'))
  let l:rid = get(a:req, 'id', '')
  if l:method ==# 'notify'
    call s:Notify(get(a:req, 'message', l:label), tolower(get(a:req, 'notifyType', 'info')))
  elseif l:method ==# 'setStatus'
    call s:SetExtStatus(get(a:req, 'statusKey', ''), get(a:req, 'statusText', v:null))
  elseif l:method ==# 'set_editor_text'
    call s:SetPromptText(get(a:req, 'text', ''))
  elseif index(s:ui_fire_and_forget, l:method) >= 0
    " Widget/title updates have no chat equivalent; they expect no reply.
    return
  elseif l:method ==# 'confirm'
    call s:UiRespond(l:rid, s:ConfirmPrompt(a:req))
  elseif l:method ==# 'select'
    call s:UiRespond(l:rid, s:SelectPrompt(a:req))
  elseif l:method ==# 'input'
    call s:UiRespond(l:rid, s:InputPrompt(a:req))
  elseif l:method ==# 'editor'
    " Not supported yet: the old scratch-buffer version blocked Vim in a
    " sleep loop inside the drain timer (the user could not type into it)
    " and always reported 'cancelled' anyway.  Cancel at once, visibly.
    call s:Notify('pi asked for a multi-line editor (' . l:label
          \ . '), which pi-chat does not support yet: cancelled', 'warning')
    call s:UiRespond(l:rid, {'cancelled': v:true})
  else
    " Unknown (future) dialog method: cancel so the extension never blocks.
    call s:UiRespond(l:rid, {'cancelled': v:true})
  endif
endfunction

" setStatus: an extension's status entry, shown after the chat statusline
" text (PiChatStatusText); no text (or null) clears the key.
function! s:SetExtStatus(key, text)
  if type(a:key) != v:t_string || a:key ==# ''
    return
  endif
  if type(a:text) == v:t_string && a:text !=# ''
    let s:ext_status[a:key] = substitute(a:text, '\n', ' ', 'g')
  elseif has_key(s:ext_status, a:key)
    call remove(s:ext_status, a:key)
  endif
  if s:buf > 0 && buflisted(s:buf) && s:FindWin() > 0
    silent! redrawstatus!
  endif
endfunction

" set_editor_text: pi (an extension) prefills the ❯ prompt.  While a turn is
" in flight the prompt is blank and typing is ignored, so the text waits in
" s:input_stash and appears when the turn ends.
function! s:SetPromptText(text)
  if type(a:text) != v:t_string || s:buf < 1 || !bufloaded(s:buf) || s:input_line < 1
    return
  endif
  let l:lines = split(a:text, "\n", 1)
  let s:input_stash = ['❯ ' . l:lines[0]] + l:lines[1:]
  if !s:busy
    call s:RestoreInputBlock()
  endif
endfunction

function! s:UiRespond(id, payload)
  if empty(a:id)
    return
  endif
  let l:p = a:payload
  let l:p.id = a:id
  let l:p.type = 'extension_ui_response'
  call s:Send(l:p)
endfunction

function! s:Notify(message, ...)
  " Level (info|warning|error, default info) drives both the transcript
  " highlight (each line gets a level marker caught by the PiChatNotice*
  " syn rules below) and the command-line echo color. pi sends the level
  " as 'notifyType'; internal callers pass it explicitly.
  let l:level = a:0 >= 1 ? tolower(a:1) : 'info'
  let l:mark = l:level ==# 'error' ? '⛔' : (l:level ==# 'warning' ? '⚠' : 'ℹ')
  let l:echogroup = l:level ==# 'error' ? 'ErrorMsg'
        \ : (l:level ==# 'warning' ? 'WarningMsg' : 'None')
  " Prefix every line of a possibly multi-line message with the marker so
  " the whole block picks up its highlight, not just the first line.
  let l:body = []
  for l:line in split(a:message, "\n", 1)
    call add(l:body, '  ' . l:mark . ' ' . l:line)
  endfor
  call s:AddLogLines(l:body)
  " echomsg (not echo), truncated to the window width: an overflowing
  " message would trigger the hit-enter prompt and block the UI. The
  " full body is already in the transcript buffer above.
  let l:msg = a:message
  if strdisplaywidth(l:msg) > winwidth(0)
    let l:msg = strcharpart(l:msg, 0, winwidth(0) - 4) . ' ...'
  endif
  " :echohl takes a literal group name, not an expression.
  execute 'echohl ' . l:echogroup
  echomsg l:msg
  echohl None
endfunction

" Prompt text for a dialog: its title, plus the message when both are set
" (confirm: title "Clear session?", message "All messages will be lost.").
function! s:DialogText(req, default)
  let l:title = get(a:req, 'title', '')
  let l:message = get(a:req, 'message', '')
  let l:parts = filter([l:title, l:message], 'type(v:val) == v:t_string && v:val !=# ""')
  return empty(l:parts) ? a:default : join(l:parts, "\n")
endfunction

" Returns the response payload: {'confirmed': 0/1}, or {'cancelled': v:true}
" when the dialog is dismissed (Esc).  The request has no 'default' field;
" Enter picks Yes.
function! s:ConfirmPrompt(req)
  return s:ConfirmPayload(confirm(s:DialogText(a:req, 'Confirm?'),
        \ "&Yes\n&No", 1, 'Question'))
endfunction

" confirm()'s answer (1 = Yes, 2 = No, 0 = dismissed) -> response payload.
function! s:ConfirmPayload(ans)
  if a:ans == 0
    return {'cancelled': v:true}
  endif
  return {'confirmed': a:ans == 1 ? v:true : v:false}
endfunction

" Display label for one select option (a string, or {id, label}).
function! s:OptionLabel(opt)
  return type(a:opt) == v:t_dict ? get(a:opt, 'label', get(a:opt, 'id', '')) : a:opt
endfunction

" Value sent back for one select option (its id, if it has one).
function! s:OptionValue(opt)
  return type(a:opt) == v:t_dict ? get(a:opt, 'id', get(a:opt, 'label', '')) : a:opt
endfunction

" Returns the extension_ui_response payload: {'value': ...}, or
" {'cancelled': v:true} when the user dismisses the list.  Always asks, even
" for a single option: the extension wants the user's decision.
function! s:SelectPrompt(req)
  let l:options = get(a:req, 'options', [])
  if type(l:options) != v:t_list || empty(l:options)
    return {'cancelled': v:true}
  endif
  " inputlist() returns the NUMBER typed, so the entries are numbered.
  let l:labels = map(copy(l:options), "'  ' . (v:key + 1) . '. ' . s:OptionLabel(v:val)")
  call insert(l:labels, s:DialogText(a:req, 'Choose:'))
  let l:pick = inputlist(l:labels)
  if l:pick < 1 || l:pick > len(l:options)
    " Esc/cancel is a cancellation, never a choice: the first option is
    " often the permissive one ("Allow dangerous command?" -> Allow).
    return {'cancelled': v:true}
  endif
  return {'value': s:OptionValue(l:options[l:pick - 1])}
endfunction

" Returns {'value': text} or {'cancelled': v:true} (Esc).  The placeholder
" is a hint, not a value, so it is shown in the prompt instead of being
" pre-filled (Enter would otherwise send the hint text as the answer).
" inputdialog()'s cancelreturn is what tells Esc apart from an empty entry.
function! s:InputPrompt(req)
  let l:prompt = s:DialogText(a:req, 'Input')
  let l:hint = get(a:req, 'placeholder', '')
  if type(l:hint) == v:t_string && l:hint !=# ''
    let l:prompt .= ' (' . l:hint . ')'
  endif
  let l:cancel = "\x01pi-chat-cancelled"
  let l:v = inputdialog(l:prompt . ': ', '', l:cancel)
  return l:v ==# l:cancel ? {'cancelled': v:true} : {'value': l:v}
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
