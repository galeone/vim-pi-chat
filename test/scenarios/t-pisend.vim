" t-pisend: :PiSend <text> sends text directly (bypassing the input buffer).
" Assert the sent prompt line and the fake's echo of it.
set nocompatible
set noswapfile

let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_context_file = 0
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')

call writefile([], '/tmp/t-pisend.txt')

function! s:Final()
  let l:b = bufnr('__PiChat__')
  let l:out = []
  if l:b > 0
    call extend(l:out, getbufline(l:b, 1, 100000))
  endif
  call writefile(l:out, '/tmp/t-pisend.txt')
  execute 'qall!'
endfunction

call timer_start(300, { -> execute('silent! PiOpen') })
call timer_start(1200, { -> execute('PiSend pi send test') })
call timer_start(2200, { -> s:Final() })
