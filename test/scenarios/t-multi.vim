" Scenario: multiple turns in one session. Expect two distinct "Echo:" replies.
set nocompatible
set noswapfile
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_context_file = 0
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')
call writefile([], '/tmp/t-multi.txt')

function! s:Send(text, ms)
  let l:b = bufnr('__PiChat__')
  if l:b < 1 | return | endif
  execute 'buffer ' . l:b
  call setline('$', a:text)
  call PiChatSendInput()
endfunction
function! s:Final(ms)
  let l:b = bufnr('__PiChat__')
  call writefile(getbufline(l:b, 1, 100000), '/tmp/t-multi.txt')
  execute 'qall!'
endfunction
call timer_start(300,  { -> execute('silent! PiOpen') })
call timer_start(900,  { -> s:Send('first question', 900) })
call timer_start(4500, { -> s:Send('second question', 4500) })
call timer_start(9000, { -> s:Final(9000) })
