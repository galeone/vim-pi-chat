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
"   :PiOpen fix the bug  open and immediately send a prompt
"   :PiSend <text>       send a prompt from the command line
"   :PiAbort             abort the current agent run
"   :PiModel <pattern>   switch model (e.g. :PiModel anthropic/claude-sonnet-4-5)
"   :PiClear             start a fresh session
"   :PiClose             close the chat and stop the agent
"   :PiThinking          toggle a panel below the chat streaming the model's
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
"   <Esc>     back to normal mode (A / i jump back to the prompt)
"   while pi is generating a turn, typing on the prompt is ignored (each
"   keystroke is reverted); :PiSend still sends/queues explicitly
"
" Closing the chat window parks the agent (buffer + transcript are kept);
" :PiOpen or :b __PiChat__ resumes the same session.
"
" Requirements:
"   - Vim 8.2+ (json_decode), compiled with +channel and +terminal
"   - the `pi` CLI on $PATH (pi auth must already be done)
"
" Configuration (set in .vimrc before the plugin loads):
"   g:pi_chat_split                'vsplit' (default), 'split', or 'new'
"   g:pi_chat_thinking_height      :PiThinking panel height (default 0.3):
"                                  integer rows or float 0-1 fraction
"   g:pi_chat_width                split width/height: integer columns/rows
"                                  (default 60) or float 0-1 for a fraction
"                                  of the screen (0.4 = 40%)
"   g:pi_chat_args                 extra pi args, e.g. ['--model', '...']
"   g:pi_chat_no_session           1 = pass --no-session (no persistence)
"   g:pi_chat_streaming_behavior   'followUp' (default) or 'steer'
"   g:pi_chat_show_thinking        1 = render thinking deltas
"   g:pi_chat_map                  global normal-mode mapping, default <leader>pi
"   g:pi_chat_context_file         1 = inject the context file into prompts
"   g:pi_chat_track_files          1 = tell pi when you switch files (:e, :b)
"
" Protocol reference: pi docs/rpc.md
" ---------------------------------------------------------------------------

if exists('g:loaded_pi_chat')
  finish
endif
if !has('job') || !has('channel')
  echohl WarningMsg
  echomsg 'pi-chat: requires Vim compiled with +job and +channel'
  echohl None
  finish
endif
if v:version < 802
  echohl WarningMsg
  echomsg 'pi-chat: requires Vim 8.2+ (json_decode)'
  echohl None
  finish
endif

let g:loaded_pi_chat = 1

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
if !exists('g:pi_chat_autosave_context')     | let g:pi_chat_autosave_context = 0 | endif
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

let s:job = ''
let s:buf = -1
let s:bufname = '__PiChat__'
" File the user was working on when :PiOpen started the session. Injected into
" prompts so the agent knows which document to read/edit (and used as the pi
" job's cwd).
let s:context_file = ''
" The pi session id in use for the current job ('' = none / pi default), and
" the resume kind chosen at start ('file', 'dir' or 'new') for the log hint.
let s:session_id = ''
let s:resumed_kind = ''
" Number of open chat windows: -1 = never opened, 0 = hidden (agent parked),
" >0 = visible.
let s:chatwins = -1
" Transcript protection (this Vim build has no :textlock). We keep an
" authoritative copy of the log in s:transcript and, on any user edit, detect a
" mismatch and restore it.
let s:transcript = []
let s:guarding = 0
let s:pinning = 0
" Reentrancy flag for s:GuardBusyInput (typing while pi is generating).
let s:typing_guard = 0
" Thinking panel (:PiThinking): a small horizontal split under the chat
" buffer where the model's thinking streams live. -1 = never created.
let s:think_buf = -1       " bufnr of the thinking panel buffer, or -1
let s:think_text = ''      " full thinking text for the current turn
" Buffers already given buffer-local markdown highlighting (avoid dupes).
let s:md_done = {}
" Optional glow(1) preview for the thinking panel: window id + temp file.
let s:think_glow_win = -1
let s:think_glow_tmp = ''
let s:think_glow_width = 80

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

" File path of the tool currently running (from the tool_execution_start
" args), so tool_execution_end can live-reload the open buffer if pi edited a
" file the user has loaded.
let s:cur_tool_path = ''

let s:running = 0
let s:queue = []
let s:drain_timer = ''
let s:req_id = 0
let s:pending_msg = ''
" 1 = about to create a brand-new session, 0 = resuming a parked one.
let s:fresh = 1

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
  if a:0 > 0
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

" getwininfo() dictionary key for the window's buffer number: recent Vims
" renamed 'winbufnr' to 'bufnr'; support both.
function! s:WinBufnr(w)
  return get(a:w, 'winbufnr', get(a:w, 'bufnr', -1))
endfunction

function! s:FindWin()
  let l:win = -1
  for l:w in getwininfo()
    if s:WinBufnr(l:w) == s:buf
      let l:win = l:w.winid
      break
    endif
  endfor
  return l:win
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
  try
    call win_gotoid(l:win)
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
      call win_gotoid(l:here)
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

" Refresh the authoritative transcript copy from the buffer's log region
" (lines 1 .. s:input_line-1). Call this after every plugin log edit so the
" copy and the buffer stay in sync before the next user edit is checked.
function! s:CaptureTranscript()
  let l:stop = s:input_line - 1
  if l:stop < 1
    let s:transcript = []
  else
    let s:transcript = getline(1, l:stop)
  endif
endfunction

" Revert any user edit to the read-only log. The plugin always edits via
" ex-commands (which do not fire TextChanged), so a change to the log region
" means the user typed into the transcript; restore the authoritative copy and
" a fresh prompt. The log is lines 1..len(s:transcript) and the input block
" must occupy at least the line below it, so any buffer shorter than that has
" had the prompt (and possibly log lines) eaten by backspace.
function! s:GuardTranscript()
  if s:guarding
    return
  endif
  if s:buf < 1 || !buflisted(s:buf) || empty(s:transcript)
    return
  endif
  let l:t = len(s:transcript)
  if line('$') < l:t + 1 || getline(1, l:t) !=# s:transcript
    let s:guarding = 1
    call setline(1, s:transcript + ['❯ '])
    if line('$') > l:t + 1
      execute (l:t + 2) . ',$delete_'
    endif
    let s:input_line = l:t + 1
    let s:tail_line = 0
    let s:tail = ''
    " Reset the reentrancy flag before touching cursor/insert mode so the guard
    " cannot be left permanently stuck if anything below raises an error.
    let s:guarding = 0
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
  let l:last = line('$')
  if l:last > s:input_line
    execute s:input_line + 1 . ',' . l:last . 'delete_'
  endif
  if a:keep && getline(s:input_line) =~# '^❯'
    return
  endif
  call setline(s:input_line, '❯ ')
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
    let b:pi_status = a:text
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
  return type(l:st) == v:t_string ? l:st : ''
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
      call s:AddLogLines(['', '⏱ pi run exceeded ' . g:pi_chat_run_timeout . 's - may be stuck; :PiClose to force-stop'])
    endif
  endif
  call s:SetStatus(l:text)
  " The window may be hidden (agent parked); redrawstatus would act on the
  " current window.
  if s:buf > 0 && buflisted(s:buf) && s:FindWin() > 0
    silent! redrawstatus
  endif
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
  if s:input_line <= line('$')
    call setline(s:input_line, '')
  endif
endfunction

" Remove the working line (if still present) and restore the ❯ prompt.
" Idempotent: the marker search simply finds nothing when there is no working
" line, so it is safe to call from every turn-end path (settle, abort, clear).
" Searches upward from the input line for the nearest ⏳ marker — s:AddLogLines
" shifts absolute line numbers as the turn streams, so a stored number would
" go stale. After deletion the prompt glyph is restored on the input line.
function! s:HideWorking()
  if s:buf < 1 || !buflisted(s:buf) || s:input_line < 1
    return
  endif
  let l:ln = 0
  " Search upward (toward the top of the buffer) from the input line for the
  " nearest working marker. The marker is the last ⏳ line above the prompt;
  " it may sit several lines up once the reply has streamed in below it.
  for l:i in range(s:input_line - 1, 1, -1)
    if stridx(getline(l:i), '⏳ pi is working') == 0
      let l:ln = l:i
      break
    endif
  endfor
  if l:ln > 0
    call deletebufline(s:buf, l:ln)
    let s:input_line -= 1
    if s:tail_line > l:ln
      let s:tail_line -= 1
    endif
  endif
  if s:input_line <= line('$')
    call setline(s:input_line, '❯ ')
  endif
  call s:CaptureTranscript()
  call s:GuardTranscript()
endfunction

" ------------------------------ thinking panel -----------------------------
" :PiThinking toggles a small horizontal panel below the chat where the
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
  if type(l:h) == v:t_number && l:h > 0 && l:h < 1
    return max(1, float2nr(&lines * l:h))
  endif
  return (type(l:h) == v:t_number && l:h > 0) ? l:h : 8
endfunction

" Called with the panel buffer current (right after `:buffer`).
function! s:ThinkBufInit()
  setlocal buftype=nofile bufhidden=hide noswapfile nonumber norelativenumber
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
  if s:think_buf < 0 || !bufexists(s:think_buf)
    return
  endif
  call s:ThinkBufWrite({ -> s:ThinkBufClear() })
endfunction

" a new prompt appends a marker line instead of clearing, so the panel keeps
" the conversation's thinking history, each turn under its prompt marker.
function! s:ThinkNewTurn(text)
  let l:head = '──── ' . substitute(a:text, '\n', ' ', 'g')
  if empty(s:think_text)
    let s:think_text = l:head . "\n"
  else
    let s:think_text .= "\n" . l:head . "\n"
  endif
  call s:FlushThinkTail()
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

" Re-renders the panel buffer from s:think_text (complete lines plus the
" trailing fragment).  The buffer is small (a few hundred lines at most), so
" a full setbufline sync per flush is cheap.  The cursor is re-parked at the
" bottom on every flush, so while the model is still thinking the panel
" always auto-scrolls to the newest line; once the stream settles the user
" is free to scroll back up (the buffer is nomodifiable, so browsing can't
" clobber the content).  Parking is a win_gotoid hop: this build's cursor()
" has no {win} argument (cursor(w, n) silently acts on the CURRENT window),
" and redraw is deferred until this flush returns, so the hop never steals
" focus.
function! s:FlushThinkTail()
  if s:think_buf < 0 || empty(s:think_text)
    return
  endif
  let l:parts = split(s:think_text, "\n", 1)
  let l:render = l:parts[:-2]  " complete lines
  if l:parts[-1] !=# ''
    call add(l:render, l:parts[-1])
  endif
  let l:old = getbufline(s:think_buf, 1, '$')
  if l:render == l:old
    return
  endif
  call s:ThinkBufWrite({ -> s:ThinkBufSync(l:render) })
  let l:win = bufwinid(s:think_buf)
  if l:win > 0
    let l:here = win_getid()
    call win_gotoid(l:win)
    call cursor(len(l:render), 1)
    call win_gotoid(l:here)
  endif
  if s:think_glow_win > 0
    call s:ThinkGlowRender()
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
  silent! bdelete! s:think_buf
  let s:think_buf = -1
  let s:think_text = ''
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
  syn match PiMdBold      '\*\*\S.*\S\*\*'
  syn match PiMdItalic    '\*\S[^*]*\S\*\|\*\S[^*]*$'
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

" -------------------- optional glow(1) markdown preview ---------------------

function! s:GlowAvailable()
  return get(g:, 'pi_chat_thinking_glow', 0) && has('terminal') && executable('glow')
endfunction

function! s:ThinkGlowOpen()
  if s:think_glow_win > 0
    return
  endif
  let s:think_glow_tmp = tempname() . '.md'
  call writefile(split(s:think_text, "\n", 1), s:think_glow_tmp)
  let l:here = win_getid()
  botright vertical split
  let s:think_glow_width = (winwidth(0) / 2) - 4
  if s:think_glow_width < 40
    let s:think_glow_width = 40
  endif
  execute 'vertical resize ' . s:think_glow_width
  terminal
  let s:think_glow_win = win_getid()
  call s:ThinkGlowRender()
  call win_gotoid(l:here)
endfunction

" Re-run glow on the temp file (a persistent shell terminal, driven by keys).
function! s:ThinkGlowRender()
  if s:think_glow_win < 0 || empty(s:think_text)
    return
  endif
  call writefile(split(s:think_text, "\n", 1), s:think_glow_tmp)
  let l:buf = winbufnr(s:think_glow_win)
  if l:buf > 0 && bufvalid(l:buf)
    try
      call term_sendkeys(l:buf, 'clear; glow -w ' . s:think_glow_width . ' ' . fnameescape(s:think_glow_tmp) . "\<CR>")
    catch
    endtry
  endif
endfunction

function! s:ThinkGlowClose()
  if s:think_glow_win > 0
    let l:here = win_getid()
    if win_gotoid(s:think_glow_win)
      close
    endif
    call win_gotoid(l:here)
    let s:think_glow_win = -1
  endif
  if !empty(s:think_glow_tmp) && filereadable(s:think_glow_tmp)
    delete(s:think_glow_tmp)
    let s:think_glow_tmp = ''
  endif
endfunction

" :PiMarkdown — open a glow(1) preview of the chat buffer in a split.
function! s:PiMarkdown()
  if !has('terminal') || !executable('glow')
    echo 'pi chat: glow not found (brew install glow) and +terminal required'
    return
  endif
  if s:buf < 1
    echo 'pi chat: no chat to preview'
    return
  endif
  let l:tmp = tempname() . '.md'
  call writefile(getbufline(s:buf, 1, '$'), l:tmp)
  let l:here = win_getid()
  botright vertical split
  let l:w = (winwidth(0) / 2) - 4
  if l:w < 40
    let l:w = 40
  endif
  execute 'vertical resize ' . l:w
  terminal
  call term_sendkeys(winbufnr(0), 'clear; glow -w ' . l:w . ' ' . fnameescape(l:tmp) . "\<CR>")
  call win_gotoid(l:here)
endfunction
command! -nargs=0 PiMarkdown call s:PiMarkdown()

" :PiOpen opens both panels: show the thinking view (text panel or glow
" preview) if it isn't already open.
function! s:PiShowThinking()
  if s:think_glow_win > 0
    return
  endif
  if s:think_buf > 0 && bufwinnr(s:think_buf) != -1
    return
  endif
  call s:PiThinking()
endfunction

function! s:PiThinking()
  " Optional glow(1) preview: drive a live terminal instead of the text panel.
  if s:GlowAvailable()
    if s:think_glow_win > 0
      call s:ThinkGlowClose()
      echo 'pi chat: thinking preview hidden (content kept)'
    else
      call s:ThinkGlowOpen()
    endif
    return
  endif
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
    call setbufline(s:think_buf, 1, '')
    " Read-only for the user: ctrl+w into the panel is fine for reading, but
    " typing/deleting streamed thinking is refused (E519).
    call setbufvar(s:think_buf, '&modifiable', 0)
  endif
  " open the new window below the chat window when we can find it
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
  " render any thinking that accumulated before the panel existed (the flush
  " parks the cursor too), then always park at the bottom so the next delta
  " is followed; via win_gotoid hops since this build's cursor() has no
  " {win} form
  call s:FlushThinkTail()
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
command! -nargs=1 PiModel call s:PiModel(<f-args>)
command!          PiClear call s:PiClear()
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
  autocmd BufEnter * call s:OnFileEnter()
augroup END

" ------------------------------ job control --------------------------------

function! s:UserPrompt(text)
  " a new prompt starts a fresh thinking block; earlier turns stay visible
  call s:ThinkNewTurn(a:text)
  call s:ClearInputBlock(0)
  call s:AddLogLines(['', '❯ ' . a:text])
  call s:ShowWorking()
  call s:CaptureTranscript()
  call s:EnsureContextSaved()
  " The agent never sees the Vim buffer list, so tell it which file the user is
  " working on; pi's read/edit tools do the rest. Unsaved buffers count too:
  " the path tells pi where to create the file.
  let l:msg = a:text
  if g:pi_chat_context_file
    let l:ctx = s:context_file
    if l:ctx ==# ''
      " No captured context file (bare `vim`): fall back to the alternate
      " buffer, i.e. whatever the user was viewing before the chat window.
      let l:ctx = expand('#:p')
    endif
    if l:ctx !=# '' && isdirectory(fnamemodify(l:ctx, ':h'))
      if filereadable(l:ctx)
        let l:msg = 'The file I am working on is: ' . l:ctx
              \ . ' (read it with your read tool; edit it in place when asked).' . "\n"
              \ . a:text
      else
        let l:msg = 'The file I am working on is: ' . l:ctx
              \ . ' (not saved to disk yet; create it when I ask for new content).' . "\n"
              \ . a:text
      endif
    endif
  endif
  let l:cmd = {'type': 'prompt', 'message': l:msg}
  if g:pi_chat_streaming_behavior !=# ''
    let l:cmd.streamingBehavior = g:pi_chat_streaming_behavior
  endif
  call s:Send(l:cmd)
  call s:BusyStart()
endfunction

function! s:JobAlive()
  if empty(s:job)
    return 0
  endif
  try
    " right after job_start() the status is still 'new'; some builds report
    " 'run' instead of 'running'
    let l:st = job_status(s:job)
    return l:st ==# 'run' || l:st ==# 'running' || l:st ==# 'new'
  catch
    return 0
  endtry
endfunction

function! s:Send(dict)
  if !s:JobAlive()
    call s:AddLogLines(['', '⚠ agent process is not running (use :PiOpen)'])
    return
  endif
  let s:req_id += 1
  let l:payload = a:dict
  let l:payload.id = 'req-' . s:req_id
  try
    call ch_sendraw(s:job, json_encode(l:payload) . "\n")
  catch
    call s:AddLogLines(['', '⚠ failed to talk to pi: ' . v:exception])
  endtry
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
" 'pchat-<len>-<hex>' where <hex> is a truncated hex encoding of the
" resolved absolute path (deterministic, so the same file always -> same id).
function! s:DeriveSessionId(path) abort
  let l:p = resolve(fnamemodify(a:path, ':p'))
  let l:hex = ''
  for l:c in split(l:p, '\zs')
    let l:hex .= printf('%02x', char2nr(l:c))
  endfor
  return printf('pchat-%d-%s', strlen(l:p), strpart(l:hex, 0, 64))
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
  if isdirectory(l:base)
    " No context file (cwd) or a directory context: the folder tier.
    return [l:base_id, s:SessionExists(l:base_id) ? 'dir' : 'new']
  endif
  " base is a file: tier 1 = its own session, tier 2 = its parent dir's.
  if s:SessionExists(l:base_id)
    return [l:base_id, 'file']
  endif
  if g:pi_chat_session_fallback_dir
    let l:dir_id = s:DeriveSessionId(fnamemodify(l:base, ':h'))
    if l:dir_id !=# l:base_id && s:SessionExists(l:dir_id)
      return [l:dir_id, 'dir']
    endif
  endif
  " Nothing to resume: key to the file (a new session will be created there).
  return [l:base_id, 'new']
endfunction

" Render a saved pi session's user/assistant conversation as chat lines so a
" resumed session shows its prior history above the input line.
function! s:LoadSessionTranscript(sid) abort
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
  let l:out = []
  for l:raw in readfile(l:files[0])
    if l:raw !~# '"type":"message"'
      continue
    endif
    try
      let l:obj = json_decode(l:raw)
    catch
      continue
    endtry
    let l:msg = get(l:obj, 'message', {})
    let l:role = type(l:msg) == v:t_dict ? get(l:msg, 'role', '') : ''
    if l:role !=# 'user' && l:role !=# 'assistant'
      continue
    endif
    let l:text = s:MessageText(l:msg)
    if empty(l:text)
      continue
    endif
    call add(l:out, l:role ==# 'user' ? '❯ ' . l:text : l:text)
  endfor
  " Cap the resumed transcript to the most recent N messages so a long session
  " never floods the chat buffer on open (0 = no cap).
  let l:cap = get(g:, 'pi_chat_resume_max_messages', 50)
  if type(l:cap) == v:t_number && l:cap > 0 && len(l:out) > l:cap
    let l:out = l:out[len(l:out) - l:cap :]
  endif
  return l:out
endfunction

" Prior thinking for a session, in order: for each assistant thinking block, a
" '──── <prompt>' marker (the flattened user message that preceded it, so the
" resumed panel reads like the live one) followed by the thinking text.
function! s:LoadSessionThinking(sid) abort
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
  let l:last_user = ''
  for l:raw in readfile(l:files[0])
    if l:raw !~# '"type":"message"'
      continue
    endif
    try
      let l:obj = json_decode(l:raw)
    catch
      continue
    endtry
    let l:msg = get(l:obj, 'message', {})
    let l:role = type(l:msg) == v:t_dict ? get(l:msg, 'role', '') : ''
    if l:role ==# 'user'
      let l:utext = s:MessageText(l:msg)
      if !empty(l:utext)
        let l:last_user = substitute(l:utext, '\n', ' ', 'g')
      endif
    elseif l:role ==# 'assistant'
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
  if !executable('pi')
    echohl ErrorMsg
    echomsg 'pi-chat: pi executable not found on PATH'
    echohl None
    return
  endif

  call s:OpenWindow()

  let s:running = 0
  let s:queue = []
  let s:tail = ''
  let s:tail_line = 0
  call s:SetStatus('pi chat')

  let l:cmd = ['pi', '--mode', 'rpc']
  let s:resumed_kind = ''
  if g:pi_chat_no_session
    call add(l:cmd, '--no-session')
    let s:session_id = ''
  elseif g:pi_chat_session_resume
    let [l:sid, s:resumed_kind] = s:ChooseSessionId(s:context_file)
    let s:session_id = l:sid
    call extend(l:cmd, ['--session-id', l:sid])
  else
    let s:session_id = ''
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
    if v:version >= 900
      " Vim 9: job_start() takes the command as a list.
      let s:job = job_start(l:cmd, l:opts)
    else
      " Vim 8: jobstart() takes a command string; shell-quote the args.
      let l:quoted = []
      for l:arg in l:cmd
        if l:arg =~# '^[A-Za-z0-9_./-]\+$'
          call add(l:quoted, l:arg)
        else
          call add(l:quoted, shellescape(l:arg))
        endif
      endfor
      let s:job = jobstart(join(l:quoted, ' '), l:opts)
    endif
  catch
    let s:job = ''
    echohl ErrorMsg
    echomsg 'pi-chat: failed to start pi: ' . v:exception
    echohl None
    return
  endtry

  " Mirror s:StopJob()'s s:StopDrain(): every (re)started job needs the drain
  " timer live to process its events. On the parked-resume path s:OpenWindow()
  " returns before s:BufSetup() (the other StartDrain call site), so without
  " this the drain stays stopped and agent_start never arrives — the chat sits
  " at "contacting pi" and replies never render.
  call s:StartDrain()

  if s:fresh
    call s:AddLogLines(['', 'pi chat — <CR> sends · <C-CR> newline · <C-c> abort'])
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
        call s:FlushThinkTail()
      endif
    endif
    call setline(line('$') + 1, '❯ ')
  else
    " Resuming: keep a half-typed prompt if there is one.
    if getline(line('$')) !~# '^❯'
      call setline(line('$'), '❯ ')
    endif
  endif
  let s:input_line = line('$')
  call s:CaptureTranscript()
  call s:GotoInputInsert()
endfunction

function! s:StopJob()
  call s:StopDrain()
  if !empty(s:job)
    try
      call ch_close(s:job)
    catch
    endtry
    try
      call job_stop(s:job)
    catch
    endtry
    let s:job = ''
  endif
  call s:BusyStop()
  let s:running = 0
  let s:queue = []
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

" Expects `provider/model-id` (e.g. anthropic/claude-sonnet-4-5); the RPC
" set_model command takes the two parts as separate fields.
function! s:PiModel(pattern)
  let l:parts = split(a:pattern, '/')
  if len(l:parts) != 2 || empty(l:parts[0]) || empty(l:parts[1])
    echohl ErrorMsg
    echomsg 'pi-chat: :PiModel expects provider/model-id, e.g. anthropic/claude-sonnet-4-5'
    echohl None
    return
  endif
  call s:Send({'type': 'set_model', 'provider': l:parts[0], 'modelId': l:parts[1]})
endfunction

" Fires on every BufEnter: react only when the current buffer is a real file
" (not chat, thinking panel, or any virtual buffer) and it differs from the
" current context file.  When the agent is running, send pi a short prompt so
" it knows the working file changed; when it is not, just remember the file
" for the next :PiOpen.
function! s:OnFileEnter() abort
  if !g:pi_chat_track_files
    return
  endif
  let l:fn = expand('%:p')
  if l:fn ==# '' || !empty(getbufvar('%', '&buftype'))
    return
  endif
  if bufnr('%') == s:buf || bufnr('%') == s:think_buf
    return
  endif
  " The chat buffers may not have buftype=nofile set yet when BufEnter
  " fires on their creation, so match their names as well.
  if bufname('%') =~# '^__PiChat'
    return
  endif
  if l:fn ==# s:context_file
    return
  endif
  let s:context_file = l:fn
  if !s:JobAlive()
    return
  endif
  let l:msg = 'I switched the file I am working on to: ' . l:fn
        \ . ' (read it with your read tool as needed).'
  call s:WithChatWin(function('s:FileSwitchLog', [l:fn]))
  let l:cmd = {'type': 'prompt', 'message': l:msg}
  if g:pi_chat_streaming_behavior !=# ''
    let l:cmd.streamingBehavior = g:pi_chat_streaming_behavior
  endif
  call s:Send(l:cmd)
endfunction

" Runs with the chat window current; keep it side-effect-free apart from the
" log line (s:WithChatWin runs the closure synchronously).
function! s:FileSwitchLog(name) abort
  call s:AddLogLines(['', 'pi-chat: context file switched: ' . a:name])
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
  call s:AddLogLines(['pi-chat: context file: ' . l:f
        \ . (s:JobAlive() ? ' (cwd applies from next :PiOpen)' : '')])
endfunction

" pi's edit/write tool just wrote a file on disk. If that file is open in a
" buffer, pull the new content in so the user sees the change live. Relative
" paths resolve against pi's cwd (the context file's directory). Never clobbers
" a buffer holding unsaved local edits - that case is flagged instead.
function! s:ReloadFile(path)
  if empty(a:path)
    return
  endif
  " Resolve a relative path against pi's working directory.
  if a:path[0] !=# '/' && a:path !~? '^[A-Za-z]:[/\\]'
    let l:base = (s:context_file !=# '' && isdirectory(fnamemodify(s:context_file, ':h')))
          \   ? fnamemodify(s:context_file, ':h')
          \   : getcwd()
    let l:fn = fnamemodify(l:base . '/' . a:path, ':p')
  else
    let l:fn = fnamemodify(a:path, ':p')
  endif
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
    call s:Notify('pi edited ' . fnamemodify(l:fn, ':t')
          \ . ' - you have unsaved changes; :e! to reload its content')
    return
  endif
  " Push the on-disk content into the buffer without switching windows.
  call setbufline(l:b, 1, readfile(l:fn))
  " setbufline() marks the buffer modified; it now matches disk, so clear it.
  call setbufvar(l:b, '&modified', 0)
  call s:Notify('reloaded ' . fnamemodify(l:fn, ':t') . ' (pi edited it)')
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
    " Win 9.0+: run :write in the buffer's window without switching to it.
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
  call s:Send({'type': 'new_session'})
  call s:ThinkReset()
  if s:buf > 0 && buflisted(s:buf) && s:input_line > 1 && s:input_line - 1 <= line('$')
    " Wipe the transcript above the input line.
    call setline(1, repeat([''], s:input_line - 1))
    let s:tail = ''
    let s:tail_line = 0
    call s:AddLogLines(['pi chat: new session', ''])
  endif
  call s:SetStatus('new session')
endfunction

function! s:PiClose(...)
  call s:ThinkCloseAll()
  if a:0 > 0 && a:1
    " invoked from BufDelete: the buffer is already gone
    let s:buf = -1
    call s:StopJob()
    return
  endif
  let l:buf = s:buf
  call s:StopJob()
  let s:buf = -1
  let s:input_line = 0
  let s:tail_line = 0
  let s:tail = ''
  let s:chatwins = -1
  let s:transcript = []
  let s:guarding = 0
  let s:pinning = 0
  if l:buf > 0 && buflisted(l:buf)
    execute 'silent! bdelete! ' . l:buf
  endif
endfunction

" Chat window count changed: closing the last window parks the agent (the
" buffer and transcript survive, bufhidden=hide keeps them alive), and
" reopening one resumes it. s:chatwins starts at -1 so the initial window
" creation (BufWinEnter with nothing to leave) can never park.
function! s:ChatWinGained()
  if s:chatwins < 0
    let s:chatwins = 0
  endif
  let s:chatwins += 1
  if s:chatwins == 1 && !s:JobAlive() && s:buf > 0 && buflisted(s:buf)
    " Resuming a parked session.
    let s:fresh = 0
    call s:StartJob()
    call s:GotoInputInsert()
  endif
endfunction

function! s:ChatWinLost()
  if s:chatwins < 1
    return
  endif
  let s:chatwins -= 1
  if s:chatwins == 0 && s:JobAlive()
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
  let l:lines = getline(s:input_line, '$')
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
  if line('$') > s:input_line
    execute s:input_line + 1 . ',' . line('$') . 'delete_'
  endif
  call setline(s:input_line, '❯ ')
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
  setlocal buftype=nofile bufhidden=hide noswapfile nonumber norelativenumber
  setlocal wrap linebreak cursorline foldcolumn=0
  setlocal statusline=%{PiChatStatusText()}

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

function! s:OnExit(ch, code)
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

function! s:OnExitFinish(was_alive, code)
  call s:CommitTail()
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
  " Run the entire tick with the chat window current (see s:WithChatWin): the
  " queued events and the spinner both edit the chat buffer by line number, so
  " they must not run while the user is in the thinking panel or elsewhere.
  call s:WithChatWin(function('s:DrainTickBody'))
endfunction

function! s:DrainTickBody()
  call s:DrainQueue()
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

  if l:sticky
    call s:GotoInput()
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
  let l:n = len(l:flat)
  if s:tail_line > 0
    call append(s:tail_line - 1, l:flat)
    let s:input_line += l:n
    let s:tail_line += l:n
  else
    call append(s:input_line - 1, l:flat)
    let s:input_line += l:n
  endif
  call s:CaptureTranscript()
endfunction

" --------------------------------- streaming --------------------------------

" stridx() is new in Vim 9.1; older Vims accept index() on strings.
function! s:StrIndex(s, sub)
  return exists('*stridx') ? stridx(a:s, a:sub) : index(a:s, a:sub)
endfunction

function! s:FlushTail()
  if s:tail ==# ''
    if s:tail_line > 0
      call setline(s:tail_line, '')
      call s:CaptureTranscript()
    endif
    return
  endif
  let l:pos = s:tail
  let l:lines = []
  let l:nl = s:StrIndex(l:pos, "\n")
  while l:nl >= 0
    call add(l:lines, l:pos[:l:nl - 1])
    let l:pos = l:pos[l:nl + 1 :]
    let l:nl = s:StrIndex(l:pos, "\n")
  endwhile
  if !empty(l:lines)
    call s:AddLogLines(l:lines)
  endif
  let s:tail = l:pos
  if s:tail_line > 0
    call setline(s:tail_line, s:tail)
  else
    call s:AddLogLines([s:tail])
    let s:tail_line = s:input_line - 1
  endif
  call s:CaptureTranscript()
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
    " Remember which file this tool targets so we can live-reload it on end.
    let s:cur_tool_path = get(l:args, 'path', get(l:args, 'file_path', ''))
    let l:detail = ''
    if has_key(l:args, 'command')
      let l:detail = '  ⚙ ' . l:name . '  ' . l:args.command
    elseif has_key(l:args, 'path')
      let l:detail = '  ⚙ ' . l:name . '  ' . l:args.path
    else
      let l:detail = '  ⚙ ' . l:name
    endif
    call s:AddLogLines([l:detail])
  elseif l:t ==# 'tool_execution_end'
    let l:tname = get(a:msg, 'toolName', 'tool')
    if get(a:msg, 'isError', v:false)
      call s:AddLogLines(['  ✗ ' . get(a:msg, 'toolName', 'tool') . ' failed'])
    else
      call s:AddLogLines(['  ✓ ' . l:tname])
      " pi's edit/write tool just wrote a file: if it's open, reload it live.
      if l:tname ==# 'edit' || l:tname ==# 'write'
        call s:ReloadFile(s:cur_tool_path)
      endif
    endif
    let s:cur_tool_path = ''
  elseif l:t ==# 'extension_ui_request'
    call s:UiRequest(a:msg)
  endif
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
    " thoughts; s:FlushThinkTail is a no-op until the buffer exists
    let s:think_text .= get(l:evt, 'delta', '')
    call s:FlushThinkTail()
  endif
endfunction

" ----------------------------- extension UI --------------------------------

" rpc.md: extension_ui_request carries `method` plus method-specific
" top-level fields (message, title, options, placeholder, prefill); the
" reply is an extension_ui_response with the same `id` and `value`
" (select/input/editor) or `confirmed` (confirm). `notify` never expects a
" reply.
function! s:UiRequest(req)
  let l:method = get(a:req, 'method', '')
  let l:label = get(a:req, 'title', get(a:req, 'message', 'pi chat'))
  let l:rid = get(a:req, 'id', '')
  if l:method ==# 'notify'
    call s:Notify(get(a:req, 'message', l:label), tolower(get(a:req, 'notifyType', 'info')))
  elseif l:method ==# 'confirm'
    call s:UiRespond(l:rid, {'confirmed': s:ConfirmPrompt(a:req)})
  elseif l:method ==# 'select'
    call s:UiRespond(l:rid, {'value': s:SelectPrompt(a:req)})
  elseif l:method ==# 'input'
    call s:UiRespond(l:rid, {'value': s:InputPrompt(a:req)})
  elseif l:method ==# 'editor'
    let l:result = s:EditorPrompt(a:req)
    if type(l:result) == v:t_string
      call s:UiRespond(l:rid, {'value': l:result})
    else
      call s:UiRespond(l:rid, {'cancelled': v:true})
    endif
  else
    " Unknown method: cancel so the extension does not block forever.
    call s:UiRespond(l:rid, {'cancelled': v:true})
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
  echohl l:echogroup
  echomsg l:msg
  echohl None
endfunction

" The protocol's confirm request has no 'default' field; default to Yes.
function! s:ConfirmPrompt(req)
  let l:msg = get(a:req, 'message', get(a:req, 'title', 'Confirm'))
  return confirm(l:msg, '&Yes' . nr2char(10) . '&No', 1, 'question') == 1
endfunction

" Display label for one select option (a string, or {id, label}).
function! s:OptionLabel(opt)
  return type(a:opt) == v:t_dict ? get(a:opt, 'label', get(a:opt, 'id', '')) : a:opt
endfunction

" Value sent back for one select option (its id, if it has one).
function! s:OptionValue(opt)
  return type(a:opt) == v:t_dict ? get(a:opt, 'id', get(a:opt, 'label', '')) : a:opt
endfunction

function! s:SelectPrompt(req)
  let l:options = get(a:req, 'options', [])
  if empty(l:options)
    return ''
  endif
  if len(l:options) == 1
    return s:OptionValue(l:options[0])
  endif
  let l:labels = map(copy(l:options), "'  ' . nr2char(65 + v:key) . ') ' . s:OptionLabel(v:val)")
  call insert(l:labels, get(a:req, 'title', get(a:req, 'message', 'Choose:')))
  let l:pick = inputlist(l:labels)
  if l:pick < 1 || l:pick > len(l:options)
    " Esc/cancel: fall back to the first option (the extension's default).
    return s:OptionValue(l:options[0])
  endif
  return s:OptionValue(l:options[l:pick - 1])
endfunction

function! s:InputPrompt(req)
  " 'message' is the prompt text; 'placeholder' pre-fills the field.
  return input(get(a:req, 'message', 'Input: ') . ': ', get(a:req, 'placeholder', ''))
endfunction

" 'editor' requests open a scratch buffer; the user edits and :w's (or :q!
" to cancel). We wait for the window to close.
function! s:EditorPrompt(req)
  " rpc.md names the editor prefill field 'prefill'; 'text' is tolerated.
  let l:text = get(a:req, 'prefill', get(a:req, 'text', ''))
  let l:curid = win_getid()
  execute 'silent! botright new'
  let l:ebuf = bufnr('%')
  setlocal buftype=acwrite bufhidden=delete noswapfile
  call setline(1, split(l:text, "\n", 1))
  augroup PiChatEditor
    autocmd!
    autocmd BufWriteCmd <buffer> call s:EditorSave()
    autocmd BufDelete  <buffer> call s:EditorCleanup()
  augroup END
  call cursor(1, 1)
  startinsert
  while buflisted(l:ebuf)
    sleep 50m
  endwhile
  call win_gotoid(l:curid)
  return s:editor_result
endfunction

function! s:EditorSave()
  let s:editor_result = join(getline(1, '$'), "\n")
  bdelete!
endfunction

function! s:EditorCleanup()
  augroup! PiChatEditor
  let s:editor_result = v:none
endfunction

let s:editor_result = v:none
let &cpo = s:save_cpo
unlet s:save_cpo
