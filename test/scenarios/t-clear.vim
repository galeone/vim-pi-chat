" vim: set ft=vim ts=2 sw=2 sts=2 et:
" Scenario: :PiClear resets the transcript. Send prompt A, clear, send prompt B.
" Expect "Echo: second" present and "Echo: first" GONE.
set nocompatible
set noswapfile
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_context_file = 0
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')
call writefile([], '/tmp/t-clear.txt')

function! s:Send(text, ms)
  let l:b = bufnr('__PiChat__')
  if l:b < 1 | return | endif
  execute 'buffer ' . l:b
  call setline('$', a:text)
  call PiChatSendInput()
endfunction
function! s:Final(ms)
  let l:b = bufnr('__PiChat__')
  let l:out = getbufline(l:b, 1, 100000)
  " Also dump the thinking panel (if open) so the runner can verify :PiClear
  " wiped the previous session's thinking from it.
  let l:tb = bufnr('__PiChatThinking__')
  if l:tb > 0
    call add(l:out, 'THINKPANEL:')
    for l:ln in getbufline(l:tb, 1, 100000)
      call add(l:out, '  ' . l:ln)
    endfor
  endif
  call writefile(l:out, '/tmp/t-clear.txt')
  execute 'qall!'
endfunction
call timer_start(300,  { -> execute('silent! PiOpen') })
call timer_start(900,  { -> s:Send('first question', 900) })
" wait for the first reply to land, then clear, then send the second.
call timer_start(4500, { -> execute('silent! PiClear') })
call timer_start(5200, { -> s:Send('second question', 5200) })
call timer_start(9500, { -> s:Final(9500) })
