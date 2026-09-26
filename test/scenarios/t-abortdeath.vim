" vim: set ft=vim ts=2 sw=2 sts=2 et:
" Scenario: pi DIES right after the abort burst (e.g. an extension throws
" "stale ctx" on the settled turn and exits 1), then the user recovers the
" panel with :PiOpen and sends again.
" Timeline (ms): open 300, prompt 800 (long turn, tool in flight),
" abort 7000 (fake plays the burst, then exits 1 at ~7300), send 9000
" (must get the "agent process is not running" warning, not a send),
" :PiOpen 10500 (restart), send 12000 (must get the OK reply).
set nocompatible
set noswapfile
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_context_file = 0
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')
call writefile([], '/tmp/t-abortdeath.txt')

function! s:Send(msg)
  let l:b = bufnr('__PiChat__')
  if l:b < 1 | return | endif
  execute 'buffer ' . l:b
  call setline('$', a:msg)
  call PiChatSendInput()
endfunction
function! s:Final()
  let l:b = bufnr('__PiChat__')
  call writefile(getbufline(l:b, 1, 100000), '/tmp/t-abortdeath.txt')
  execute 'qall!'
endfunction
call timer_start(300,  { -> execute('silent! PiOpen') })
call timer_start(800,  { -> s:Send('long turn') })
call timer_start(7000, { -> execute('silent! PiAbort') })
call timer_start(9000, { -> s:Send('after death') })
call timer_start(10500, { -> execute('silent! PiOpen') })
call timer_start(12000, { -> s:Send('follow up') })
call timer_start(15500, { -> s:Final() })
