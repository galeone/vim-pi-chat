" vim: set ft=vim ts=2 sw=2 sts=2 et:
" Scenario: while a turn is in flight the chat shows a "⏳ pi is working…"
" line and hides the input prompt; on settle the line is removed and the
" "❯ " prompt is restored.
"
" The runner sets FAKE_PI_DELAY_MS large (see test/run.sh) so the fake's reply
" burst lands AFTER the mid dump. We capture the buffer twice:
"   mid  -> /tmp/t-working-mid.txt  : while in flight (expect working line)
"   final-> /tmp/t-working.txt      : after settle  (expect reply, no working)
set nocompatible
set noswapfile
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_context_file = 0
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')
call writefile([], '/tmp/t-working.txt')
call writefile([], '/tmp/t-working-mid.txt')

function! s:Send()
  let l:b = bufnr('__PiChat__')
  if l:b < 1 | return | endif
  execute 'buffer ' . l:b
  call setline('$', 'hello fake')
  call PiChatSendInput()
endfunction
function! s:MidDump()
  let l:b = bufnr('__PiChat__')
  call writefile(getbufline(l:b, 1, 100000), '/tmp/t-working-mid.txt')
endfunction
function! s:Final()
  let l:b = bufnr('__PiChat__')
  call writefile(getbufline(l:b, 1, 100000), '/tmp/t-working.txt')
  execute 'qall!'
endfunction
call timer_start(300,  { -> execute('silent! PiOpen') })
call timer_start(900,  { -> s:Send() })
call timer_start(2000, { -> s:MidDump() })
call timer_start(5500, { -> s:Final() })
