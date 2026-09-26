" vim: set ft=vim ts=2 sw=2 sts=2 et:
" Scenario: switching the current file (:e) updates the context file and tells
" pi about it. Two switches -> exactly two "I switched the file..." prompts;
" re-editing the same buffer does not re-notify.
set nocompatible
set noswapfile
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_context_file = 0
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')
call writefile([], '/tmp/t-trackfile.txt')
let s:userwin = win_getid()

call writefile(['alpha'], '/tmp/t-trackfile-a.txt')
call writefile(['beta'], '/tmp/t-trackfile-b.txt')

function! s:SwitchTo(f)
  call win_gotoid(s:userwin)
  execute 'silent edit' fnameescape(a:f)
endfunction

function! s:Final()
  let l:b = bufnr('__PiChat__')
  let l:lines = getbufline(l:b, 1, 100000)
  if $FAKE_PI_LOG !=# '' && filereadable($FAKE_PI_LOG)
    call extend(l:lines, ['--- fake pi stdin ---'])
    call extend(l:lines, readfile($FAKE_PI_LOG))
  endif
  call writefile(l:lines, '/tmp/t-trackfile.txt')
  execute 'qall!'
endfunction

call timer_start(300,  { -> execute('silent! PiOpen') })
call timer_start(1200, { -> s:SwitchTo('/tmp/t-trackfile-a.txt') })
call timer_start(2400, { -> s:SwitchTo('/tmp/t-trackfile-b.txt') })
call timer_start(3400, { -> s:SwitchTo('/tmp/t-trackfile-b.txt') })
call timer_start(4800, { -> s:Final() })
