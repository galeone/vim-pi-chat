" Scenario: notify levels render with distinct markers.
" With FAKE_PI_NOTIFY_ALL=1 the fake emits info/warning/error notifies.
" Expect the 'ℹ info note' / '⚠ warn note' / '⛔ error note' lines present.
set nocompatible
set noswapfile
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_context_file = 0
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')
call writefile([], '/tmp/t-notify.txt')

function! s:Send(text, ms)
  let l:b = bufnr('__PiChat__')
  if l:b < 1 | return | endif
  execute 'buffer ' . l:b
  call setline('$', a:text)
  call PiChatSendInput()
endfunction
function! s:Final(ms)
  let l:b = bufnr('__PiChat__')
  call writefile(getbufline(l:b, 1, 100000), '/tmp/t-notify.txt')
  execute 'qall!'
endfunction
call timer_start(300,  { -> execute('silent! PiOpen') })
call timer_start(900,  { -> s:Send('hello', 900) })
call timer_start(3500, { -> s:Final(3500) })
