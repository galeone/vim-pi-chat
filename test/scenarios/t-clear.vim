" vim: set ft=vim ts=2 sw=2 sts=2 et:
" Scenario: :PiClear resets the transcript. Send prompt A, clear, send prompt B.
" Expect "Echo: second" present and "Echo: first" GONE.
set nocompatible
set noswapfile
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_context_file = 0
call delete('/tmp/t-clear-sessions', 'rf')
let g:pi_chat_session_dir = '/tmp/t-clear-sessions'

" Seed a pre-clear session file under the context (folder) id, mirroring the
" plugin's DeriveSessionId, so :PiClear has something to delete and the test
" can assert the old session file is gone (a later :PiOpen must then resume
" the post-clear session, not this one).
function! s:Derive(p)
  let l:p = resolve(fnamemodify(a:p, ':p'))
  let l:hex = ''
  for l:c in split(l:p, '\zs')
    let l:hex .= printf('%02x', char2nr(l:c))
  endfor
  return printf('pchat-%d-%s', strlen(l:p), strpart(l:hex, 0, 64))
endfunction
let s:pre = g:pi_chat_session_dir . '/cwd/' . s:Derive(getcwd()) . '.jsonl'
call mkdir(fnamemodify(s:pre, ':h'), 'p')
call writefile(['{"type":"message"}'], s:pre)

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
  call add(l:out, 'cleared-old: ' . (!filereadable(s:pre)))
  call writefile(l:out, '/tmp/t-clear.txt')
  execute 'qall!'
endfunction
call timer_start(300,  { -> execute('silent! PiOpen') })
call timer_start(900,  { -> s:Send('first question', 900) })
" wait for the first reply to land, then clear, then send the second.
call timer_start(4500, { -> execute('silent! PiClear') })
call timer_start(5200, { -> s:Send('second question', 5200) })
call timer_start(9500, { -> s:Final(9500) })
