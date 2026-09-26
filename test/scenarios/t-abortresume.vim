" vim: set ft=vim ts=2 sw=2 sts=2 et:
" Scenario: after :PiAbort mid-turn, a new prompt sent through the normal
" <CR> path (PiChatSendInput) must still reach the agent and get a reply.
" Reproduces: user aborted a stuck turn, then could no longer "reach pi"
" in the panel until fully restarting vim.
" With FAKE_PI_DELAY_MS/TURN_MS sized so prompt 1 is mid-turn at abort
" time, the fake also leaks prompt 1's leftover tool frames after the
" abort (like real pi's post-abort message_end/turn_end flood).
set nocompatible
set noswapfile
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_context_file = 0
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')
call writefile([], '/tmp/t-abortresume.txt')

function! s:Send(msg)
  let l:b = bufnr('__PiChat__')
  if l:b < 1 | return | endif
  execute 'buffer ' . l:b
  call setline('$', a:msg)
  call PiChatSendInput()
endfunction
function! s:Final()
  let l:b = bufnr('__PiChat__')
  call writefile(getbufline(l:b, 1, 100000), '/tmp/t-abortresume.txt')
  execute 'qall!'
endfunction
call timer_start(300,  { -> execute('silent! PiOpen') })
call timer_start(900,  { -> s:Send('first prompt') })
call timer_start(2500, { -> execute('silent! PiAbort') })
call timer_start(4000, { -> s:Send('second prompt') })
call timer_start(8500, { -> s:Final() })
