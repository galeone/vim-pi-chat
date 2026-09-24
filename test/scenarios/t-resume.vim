" t-resume: file-keyed session resume wiring. On :PiOpen the plugin derives a
" stable id from the opened file's resolved path and launches pi with
" `--session-id pchat-<len>-<hash>` (create-or-resume). The id is derived from
" the path, so it is path-keyed + deterministic: a later :PiOpen for the same
" file passes the SAME id, and pi resumes that session. The fake pi persists no
" session, so resume-with-context isn't exercised here — only that the correct
" `--session-id` (a startup arg, not a stdin line) is passed. Checked via the
" fake's argv log (FAKE_PI_ARGV_LOG).
set nocompatible
set noswapfile

let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')

" A context file with content, so :PiOpen keys the session to it (file tier).
let s:ctx = resolve(tempname())
call setline(1, 'resume target')
call writefile(['resume target'], s:ctx)
let g:pi_chat_context_file = s:ctx

execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')

call writefile([], '/tmp/t-resume.txt')
call timer_start(300, { -> execute('silent! PiOpen') })
call timer_start(900, { -> s:WaitArgv(0) })

function! s:WaitArgv(n)
  if filereadable('/tmp/fakepi-argv.log') && !empty(readfile('/tmp/fakepi-argv.log'))
    let l:first = readfile('/tmp/fakepi-argv.log')[0]
    let l:m = l:first =~# '"--session-id","pchat-[^"]*"'
    let l:id = l:m ? substitute(l:first, '.*"--session-id","\(pchat-[^"]*\)".*', '\1', '') : ''
    call writefile(['session_id_match=' . l:m
                  \ . ' pchat=' . (l:id =~# '^pchat-')
                  \ . ' id=' . l:id], '/tmp/t-resume.txt')
    execute 'qall!'
  elseif a:n < 40
    call timer_start(100, { -> s:WaitArgv(a:n + 1) })
  else
    call writefile(['no argv log'], '/tmp/t-resume.txt')
    execute 'qall!'
  endif
endfunction
