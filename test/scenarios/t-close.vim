" vim: set ft=vim ts=2 sw=2 sts=2 et:
" t-close: :PiOpen then :PiClose -> the chat window is closed and the chat
" buffer is no longer listed / shown in any window.
set nocompatible
set noswapfile

let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
let g:pi_chat_context_file = 0
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')

call writefile([], '/tmp/t-close.txt')

function! s:Final()
  let l:b = bufnr('__PiChat__')
  let l:out = [
        \ 'wins:' . winnr('$'),
        \ 'bufwinnr:' . (l:b > 0 ? bufwinnr(l:b) : -1),
        \ 'listed:' . (l:b > 0 ? buflisted(l:b) : -1),
        \ ]
  call writefile(l:out, '/tmp/t-close.txt')
  execute 'qall!'
endfunction

call timer_start(300, { -> execute('silent! PiOpen') })
call timer_start(1200, { -> execute('silent! PiClose') })
call timer_start(1800, { -> s:Final() })
