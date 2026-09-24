" Scenario: thinking is HIDDEN when g:pi_chat_show_thinking=0 (the default).
" Runner env: FAKE_PI_THINKING=1. Expect the "Echo:" reply but NO "Thinking:" line.
set nocompatible
set noswapfile
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_show_thinking = 0
let g:pi_chat_context_file = 0
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')
call writefile([], '/tmp/t-thinkoff.txt')

function! s:SendAt(ms)
  let l:b = bufnr('__PiChat__')
  if l:b < 1 | return | endif
  execute 'buffer ' . l:b
  call setline('$', 'think about it')
  call PiChatSendInput()
endfunction
function! s:Final(ms)
  let l:b = bufnr('__PiChat__')
  call writefile(getbufline(l:b, 1, 100000), '/tmp/t-thinkoff.txt')
  call writefile([a:ms . ': ' . PiChatStatusText()], '/tmp/t-thinkoff-status.txt', 'a')
  execute 'qall!'
endfunction
call timer_start(300,  { -> execute('silent! PiOpen') })
call timer_start(1000, { -> s:SendAt(1000) })
call timer_start(9000, { -> s:Final(9000) })
