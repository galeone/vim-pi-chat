" Scenario: :PiAbort requests an abort. Sends a prompt, then :PiAbort.
" Expect the "⚠ abort requested" transcript line.
set nocompatible
set noswapfile
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_context_file = 0
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')
call writefile([], '/tmp/t-abort.txt')

function! s:Send()
  let l:b = bufnr('__PiChat__')
  if l:b < 1 | return | endif
  execute 'buffer ' . l:b
  call setline('$', 'abort me')
  call PiChatSendInput()
endfunction
function! s:Final()
  let l:b = bufnr('__PiChat__')
  call writefile(getbufline(l:b, 1, 100000), '/tmp/t-abort.txt')
  execute 'qall!'
endfunction
call timer_start(300,  { -> execute('silent! PiOpen') })
call timer_start(900,  { -> s:Send() })
call timer_start(1800, { -> execute('silent! PiAbort') })
call timer_start(2600, { -> s:Final() })
