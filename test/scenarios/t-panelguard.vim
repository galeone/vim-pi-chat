" vim: set ft=vim ts=2 sw=2 sts=2 et:
" Scenario: a stray `:e file` typed while the cursor is on the chat panel must
" land in the file window, and the panel must stay in its own window.
"
" The plugin watches BufEnter (s:PanelGuard): when a real file buffer takes
" over a panel window it swaps the file into the last real-file window and
" restores the panel in place, then tells pi about the switch.  Here we `:e`
" from the chat window itself (exactly the muscle-memory accident this guards
" against) and verify:
"   1. the chat window still shows the chat buffer,
"   2. a different window shows the new file,
"   3. pi was told about the switch (prompt + chat-buffer log line).
set nocompatible
set noswapfile
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')
call writefile([], '/tmp/t-panelguard.txt')

call writefile(['alpha'], '/tmp/panel-a.txt')
call writefile(['beta'], '/tmp/panel-b.txt')
execute 'silent edit /tmp/panel-a.txt'

function! s:Final()
  " 1. the chat window (still current) must show the chat buffer
  if bufname('%') ==# '__PiChat__'
    call add(s:out, 'panel-ok: current window shows the chat buffer')
  else
    call add(s:out, 'panel-FAIL: current window shows ' . bufname('%'))
  endif
  " 2. the new file must live in a different window
  let l:filewin = bufwinnr('/tmp/panel-b.txt')
  if l:filewin > 0 && l:filewin != winnr()
    call add(s:out, 'filewindow-ok: /tmp/panel-b.txt in window ' . l:filewin)
  else
    call add(s:out, 'filewindow-FAIL: bufwinnr=' . l:filewin)
  endif
  let l:lines = getbufline(bufnr('__PiChat__'), 1, 100000)
  call extend(l:lines, s:out)
  call add(l:lines, '--- end of checks ---')
  if $FAKE_PI_LOG !=# '' && filereadable($FAKE_PI_LOG)
    call extend(l:lines, ['--- fake pi stdin ---'])
    call extend(l:lines, readfile($FAKE_PI_LOG))
  endif
  call writefile(l:lines, '/tmp/t-panelguard.txt')
  execute 'qall!'
endfunction

let s:out = []
call timer_start(300, { -> execute('silent! PiOpen') })
call timer_start(1500, { -> execute('e /tmp/panel-b.txt') })
call timer_start(3000, { -> s:Final() })
