" t-stall: the hang watchdog fires on a stalled (no-reply) run
"
" pi_chat_run_timeout=1 and FAKE_PI_DELAY_MS=2000 keep pi quiet past the 1s
" budget, so the spinner status gains a ':PiClose to stop' hint and the
" transcript gets the one-time 'pi run exceeded' stall line. Send at 1000ms,
" watchdog fires ~1s after the busy starts (~2000ms), dump at 2200ms.

set nocompatible
set noswapfile
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let $FAKE_PI_DELAY_MS = '2000'
let g:pi_chat_run_timeout = 1
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')
call writefile([], '/tmp/t-stall.txt')

function! s:SendAt(ms)
  let l:b = bufnr('__PiChat__')
  if l:b < 1 | return | endif
  execute 'buffer ' . l:b
  call setline('$', 'stall probe')
  call PiChatSendInput()
endfunction
function! s:Final(ms)
  let l:b = bufnr('__PiChat__')
  call writefile(getbufline(l:b, 1, 100000), '/tmp/t-stall.txt')
  execute 'qall!'
endfunction
call timer_start(300,  { -> execute('silent! PiOpen') })
call timer_start(1000, { -> s:SendAt(1000) })
call timer_start(2200, { -> s:Final(2200) })
