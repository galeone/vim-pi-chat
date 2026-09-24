" Scenario: :PiFile attaches a context file. Expect an "added context file" log line.
set nocompatible
set noswapfile
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_context_file = 0
call writefile(['important context line'], '/tmp/t-pifile-ctx.txt')
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')
call writefile([], '/tmp/t-pifile.txt')

function! s:Final(ms)
  let l:b = bufnr('__PiChat__')
  call writefile(getbufline(l:b, 1, 100000), '/tmp/t-pifile.txt')
  execute 'qall!'
endfunction
call timer_start(300,  { -> execute('silent! PiOpen') })
call timer_start(1200, { -> execute('silent! PiFile /tmp/t-pifile-ctx.txt') })
call timer_start(4000, { -> s:Final(4000) })
