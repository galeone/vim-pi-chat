" vim: set ft=vim ts=2 sw=2 sts=2 et:
" Scenario: post-abort recovery against the REAL pi protocol.
" Driven by test/replay/bin/pi, which replays frames captured verbatim
" from `pi --mode rpc`: a long turn with a bash tool left in flight, a
" :PiAbort mid-tool (real post-abort event flood), then a follow-up
" prompt through the normal <CR> path that must still reach the agent.
" Reproduces the user report: after :PiAbort the panel could no longer
" reach pi until a full vim restart.
set nocompatible
set noswapfile
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_context_file = 0
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')
call writefile([], '/tmp/t-abortreplay.txt')

function! s:Send(msg)
  let l:b = bufnr('__PiChat__')
  if l:b < 1 | return | endif
  execute 'buffer ' . l:b
  call setline('$', a:msg)
  call PiChatSendInput()
endfunction
function! s:Final()
  let l:b = bufnr('__PiChat__')
  call writefile(getbufline(l:b, 1, 100000), '/tmp/t-abortreplay.txt')
  execute 'qall!'
endfunction
call timer_start(300,  { -> execute('silent! PiOpen') })
call timer_start(800,  { -> s:Send('long turn') })
call timer_start(7000, { -> execute('silent! PiAbort') })
call timer_start(8500, { -> s:Send('follow up') })
call timer_start(12500, { -> s:Final() })
