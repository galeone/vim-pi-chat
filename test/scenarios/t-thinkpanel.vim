" vim: set ft=vim ts=2 sw=2 sts=2 et:
" Scenario: :PiThinking opens a separate panel buffer that streams the
" model's thinking live (g:pi_chat_show_thinking stays 0, so the chat buffer
" must NOT receive the thinking text).  Toggle off keeps the buffer content,
" toggle on restores the window.  Runner env: FAKE_PI_THINKING=1.
set nocompatible
set noswapfile
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_context_file = 0
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')
call writefile([], '/tmp/t-thinkpanel.txt')

let s:states = []
function! s:State(label)
  let l:pb = bufnr('__PiChatThinking__')
  call add(s:states, a:label
        \ . ' wins: ' . len(getwininfo())
        \ . ' panel: ' . (l:pb > 0 ? 'buf' : 'none')
        \ . ' open: ' . (l:pb > 0 && bufwinnr(l:pb) != -1 ? 'yes' : 'no')
        \ . ' lines: ' . (l:pb > 0 ? len(getbufline(l:pb, 1, '$')) : 0))
endfunction
function! s:SendAt(ms)
  " type into the CHAT window (jump to it by ID - a bare :buffer would act on
  " whatever window happens to be current).
  for l:w in getwininfo()
    if l:w.bufnr == bufnr('__PiChat__')
      call win_gotoid(l:w.winid)
      break
    endif
  endfor
  call setline('$', 'think about it')
  call PiChatSendInput()
endfunction
function! s:Final(ms)
  let l:pb = bufnr('__PiChatThinking__')
  let l:out = s:states
  call add(l:out, 'final wins: ' . len(getwininfo()))
  if l:pb > 0
    call extend(l:out, getbufline(l:pb, 1, 100000))
  endif
  call writefile(l:out, '/tmp/t-thinkpanel.txt')
  execute 'qall!'
endfunction
call timer_start(300,  { -> execute('silent! PiOpen') })
call timer_start(800,  { -> execute('silent! PiThinking') })
call timer_start(1000, { -> s:SendAt(1000) })
call timer_start(4000, { -> execute('call s:State("t4off") | silent! PiThinking') })
call timer_start(6000, { -> execute('call s:State("t6on") | silent! PiThinking') })
call timer_start(9000, { -> s:Final(9000) })
