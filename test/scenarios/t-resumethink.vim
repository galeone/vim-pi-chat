" t-resumethink.vim — verifying the thinking panel resumes prior turns from a
" pi session, the same way the chat resumes its transcript. A fake session
" (hermetic g:pi_chat_session_dir) holds two user/assistant turns with thinking;
" a fresh :PiOpen on that context file must load the transcript into the chat
" and the thinking into the panel (rendered when :PiThinking is opened).
set nocompatible
set noswapfile

let s:out = '/tmp/t-resumethink.txt'
call writefile([''], s:out)

" Hermetic session dir + a context file that has a prior session with thinking.
let s:tmp = '/tmp/t-resumethink-session'
call system('rm -rf ' . s:tmp)
call mkdir(s:tmp . '/sess', 'p')
let s:ctx = s:tmp . '/f.txt'
call writefile([''], s:ctx)
let g:pi_chat_session_dir = s:tmp
let g:pi_chat_session_resume = 1
let g:pi_chat_show_thinking = 1

" Source the plugin first so :PiOpen / :PiThinking exist for the timers below.
let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')
execute "source " . fnameescape(s:root . '/plugin/pi_chat.vim')

" Replicate the plugin's deterministic session-id derivation (same formula).
function! s:Sid(path) abort
  let l:p = resolve(fnamemodify(a:path, ':p'))
  let l:hex = ''
  for l:c in split(l:p, '\zs')
    let l:hex .= printf('%02x', char2nr(l:c))
  endfor
  return printf('pchat-%d-%s', strlen(l:p), strpart(l:hex, 0, 64))
endfunction

let s:sid = s:Sid(s:ctx)
let s:sfile = s:tmp . '/sess/2026-01-01T00-00-00-000Z_' . s:sid . '.jsonl'
call writefile([
  \ '{"type":"session","id":"' . s:sid . '"}',
  \ '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"prior question"}]}}',
  \ '{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"PRIOR THOUGHT ONE","thinkingSignature":"x"},{"type":"text","text":"prior answer"}]}}',
  \ '{"type":"message","message":{"role":"user","content":[{"type":"text","text":"second question"}]}}',
  \ '{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"PRIOR THOUGHT TWO","thinkingSignature":"x"},{"type":"text","text":"second answer"}]}}',
  \ ], s:sfile)

" Open the chat on the context file so the session id matches the planted file.
execute 'edit ' . fnameescape(s:ctx)
call timer_start(300,  { -> execute('silent! PiOpen') })
call timer_start(1600, { -> s:Final() })

function! s:Final()
  let l:chat = bufnr('__PiChat__')
  let l:panel = bufnr('__PiChatThinking__')
  let l:cl = l:chat > 0 ? getbufline(l:chat, 1, '$') : []
  let l:pl = l:panel > 0 ? getbufline(l:panel, 1, '$') : []
  let l:ctext = join(l:cl, "\n")
  let l:ptext = join(l:pl, "\n")
  let l:out = [
    \ 'session-file-exists: ' . filereadable(s:sfile),
    \ 'chat-resumed-marker: ' . (l:ctext =~# 'resumed'),
    \ 'chat-transcript-1: ' . (l:ctext =~# 'prior answer'),
    \ 'chat-transcript-2: ' . (l:ctext =~# 'second answer'),
    \ 'panel-open: ' . (l:panel > 0 ? bufwinnr(l:panel) : 0),
    \ 'panel-thought-1: ' . (l:ptext =~# 'PRIOR THOUGHT ONE'),
    \ 'panel-thought-2: ' . (l:ptext =~# 'PRIOR THOUGHT TWO'),
    \ 'panel-marker-1: ' . (l:ptext =~# '──── prior question'),
    \ 'panel-marker-2: ' . (l:ptext =~# '──── second question'),
    \ '',
    \ '─── chat panel ───',
    \ ]
  call extend(l:out, l:cl)
  call add(l:out, '─── thinking panel ───')
  if l:panel > 0
    call extend(l:out, l:pl)
  else
    call add(l:out, '(thinking panel not open)')
  endif
  call writefile(l:out, s:out)
  execute 'qall!'
endfunction
