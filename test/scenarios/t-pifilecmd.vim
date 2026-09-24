" Scenario: the :PiFile command (not just the config default) sets the context.
" Expect the "pi-chat: context file: <path>" line for the file we name.
set nocompatible
set noswapfile
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_context_file = 0
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')
call writefile([], '/tmp/t-pifilecmd.txt')

function! s:Final()
  let l:b = bufnr('__PiChat__')
  call writefile(getbufline(l:b, 1, 100000), '/tmp/t-pifilecmd.txt')
  execute 'qall!'
endfunction
call timer_start(300, { -> execute('silent! PiOpen') })
call timer_start(900, { -> execute('PiFile ' . fnameescape(s:root . '/plugin/pi_chat.vim')) })
call timer_start(1600, { -> s:Final() })
