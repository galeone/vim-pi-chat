" vim: set ft=vim ts=2 sw=2 sts=2 et:
" Scenario: a mid-stream window switch must not corrupt the chat buffer.
"
" With the thinking panel OPEN, send a prompt, then make the panel the
" CURRENT window.  The 50ms drain timer fires with the panel current while
" the reply bursts in.  The chat pipeline (s:AddLogLines/s:FlushTail/
" s:CaptureTranscript) addresses the CURRENT window by line number, so it
" must be hopped to the chat window (s:WithChatWin) - otherwise the reply is
" appended into the nomodifiable panel (E21) and s:CaptureTranscript copies
" the *panel's* text into s:transcript, which the next s:GuardTranscript then
" dumps into the chat (the "thinking leaked into chat" bug).
"
" After the stream settles we dump the CHAT buffer: it must contain the
" reply and must NOT contain the thinking text.  The runner also fails the
" run if any Vim E-error appears (the old code raised E21 here).
set nocompatible
set noswapfile
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_context_file = 0
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')
call writefile([], '/tmp/t-leak.txt')

function! s:WinOf(b)
  for l:w in getwininfo()
    if l:w.bufnr == a:b
      return l:w.winid
    endif
  endfor
  return -1
endfunction

function! s:SendAndSwitchToPanel()
  " type into the chat window and send, then make the THINKING PANEL the
  " current window so the drain tick that processes the burst runs with a
  " non-chat window current.
  let l:chat = s:WinOf(bufnr('__PiChat__'))
  if l:chat > 0
    call win_gotoid(l:chat)
  endif
  call setline('$', 'leak check prompt')
  call PiChatSendInput()
  let l:panel = s:WinOf(bufnr('__PiChatThinking__'))
  if l:panel > 0
    call win_gotoid(l:panel)
  endif
endfunction

function! s:Final()
  let l:out = ['=== CHAT BUFFER (want the Echo reply; the panel thinking must NOT appear here) ===']
  call extend(l:out, getbufline(bufnr('__PiChat__'), 1, '$'))
  call writefile(l:out, '/tmp/t-leak.txt')
  execute 'qall!'
endfunction

call timer_start(300,  { -> execute('silent! PiOpen') })
call timer_start(800,  { -> execute('silent! PiThinking') })
call timer_start(1000, { -> s:SendAndSwitchToPanel() })
call timer_start(3000, { -> s:Final() })
