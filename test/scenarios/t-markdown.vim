" t-markdown: verify g:pi_chat_markdown wires the PiMd* markdown highlighting.
"
" HEADLESS NOTE: this vim build's --not-a-term mode does not render syntax
" highlighting (synID/synIDtrans/synIDattr all return the EMPTY group for every
" line, even with `syntax enable`), so a line-level "this heading resolves to
" PiMdHeading" check is impossible here. Instead we assert what IS observable,
" on three levels, for the representative groups:
"   1. the highlight group is DEFINED (hlexists),
"   2. its `:hi def link` target is correct (:hi shows "links to <target>"),
"   3. a real syn match/region ITEM exists for it (`:syntax list <grp>` does not
"      say "No Syntax items") — this catches the case where the hi links exist
"      but the syn lines silently failed (the E401 "buffer keyword" crash).
" If the markdown gate is off, s:ApplyMarkdown skips all of it and the groups
" are absent, failing level 1.
"
" This file is run as:  vim --not-a-term -Nu t-markdown.vim
" (no plugin dir needed; we source the plugin ourselves).

let s:root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')

" Markdown on (default, but set explicitly to be robust).
let g:pi_chat_markdown = 1

" Pre-create the dump so a hard abort still leaves a readable file.
call writefile(['(t-markdown dump)'], '/tmp/t-markdown.txt')

" Source the plugin from the repo (the CWD is not on the rtp here).
execute 'source ' . fnameescape(s:root . '/plugin/pi_chat.vim')

" :PiMarkdown is a user :command; exists(':PiMarkdown') is 1 or 2 when registered.
"
" s:GroupStatus(grp, want): report the full state of one PiMd* group.
"   'absent'         -> highlight group not defined (markdown off / not applied)
"   'link-mismatch'  -> group defined but :hi does not link to <want>
"   'item-missing'   -> group defined + linked but has no syn match/region item
"   'ok'             -> defined, linked correctly, and the syn item exists
" hlexists(:hi) and :syntax list are hlexists-guarded / non-fatal.
function! s:GroupStatus(grp, want)
    if !hlexists(a:grp)
        return 'absent'
    endif
    if execute('hi ' . a:grp) !~# 'links to ' . a:want
        return 'link-mismatch'
    endif
    if execute('syntax list ' . a:grp) =~? 'no syntax'
        return 'item-missing'
    endif
    return 'ok'
endfunction

function! s:Check()
    let l:out = [
                \ 'markdown: ' . g:pi_chat_markdown,
                \ 'piMarkdown-cmd: ' . exists(':PiMarkdown'),
                \ 'PiMdHeading: ' . s:GroupStatus('PiMdHeading', 'Title'),
                \ 'PiMdCode: ' . s:GroupStatus('PiMdCode', 'Special'),
                \ 'PiMdList: ' . s:GroupStatus('PiMdList', 'Keyword'),
                \ ]
    call writefile(l:out, '/tmp/t-markdown.txt')
    execute 'qall!'
endfunction

" PiOpen (runs s:BufSetup -> s:ApplyMarkdown, defining the items) then check.
call timer_start(300, { -> execute('silent! PiOpen') })
call timer_start(2000, { -> s:Check() })
