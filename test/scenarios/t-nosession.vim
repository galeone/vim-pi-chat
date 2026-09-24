" vim: set ft=vim ts=2 sw=2 sts=2 et:
" t-nosession: with g:pi_chat_no_session=1 the job is started with --no-session,
" a STARTUP arg (not a stdin line), so verify it via the fake's argv log
" (/tmp/fakepi-argv.log, exported by run.sh). job_start is async, so poll for
" the argv log rather than reading it at a fixed time.
set nocompatible
set noswapfile

let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_no_session = 1
let g:pi_chat_context_file = 0
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')

call writefile([], '/tmp/t-nosession.txt')

function! s:WaitArgv(n)
  if filereadable('/tmp/fakepi-argv.log') && !empty(readfile('/tmp/fakepi-argv.log'))
    call writefile(readfile('/tmp/fakepi-argv.log'), '/tmp/t-nosession.txt')
    execute 'qall!'
  elseif a:n < 40
    call timer_start(100, { -> s:WaitArgv(a:n + 1) })
  else
    call writefile(['no argv log'], '/tmp/t-nosession.txt')
    execute 'qall!'
  endif
endfunction

call timer_start(300, { -> execute('silent! PiOpen') })
call timer_start(800, { -> s:WaitArgv(0) })
