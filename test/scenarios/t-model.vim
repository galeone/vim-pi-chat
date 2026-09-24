" t-model: :PiModel 'openai/gpt-x' sends set_model over stdin. The chat buffer
" is not dumped for this case; verify the exact stdin line via the fake's FAKE_PI_LOG
" (/tmp/fakepi-model.log, exported by run.sh). Poll for the set_model line because
" job_start is async.
set nocompatible
set noswapfile

let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_context_file = 0
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')

call writefile([], '/tmp/t-model.txt')

function! s:WaitSetModel(n)
  if filereadable('/tmp/fakepi-model.log')
    let l:hits = filter(readfile('/tmp/fakepi-model.log'), 'v:val =~# "set_model"')
    if !empty(l:hits)
      call writefile(l:hits, '/tmp/t-model.txt')
      execute 'qall!'
      return
    endif
  endif
  if a:n < 40
    call timer_start(100, { -> s:WaitSetModel(a:n + 1) })
  else
    call writefile([], '/tmp/t-model.txt')
    execute 'qall!'
  endif
endfunction

call timer_start(300, { -> execute('silent! PiOpen') })
call timer_start(900, { -> execute('silent! PiModel openai/gpt-x') })
call timer_start(1100, { -> s:WaitSetModel(0) })
