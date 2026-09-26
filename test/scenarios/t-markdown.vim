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
"   4. render: the nested-vim byte dump proves **text** resolves to PiMdBold
"      (not PiMdItalic) and *text* to PiMdItalic — the bold/italic
"      precedence regression guard.
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

" Render check: does **text** actually resolve to bold (not italic), and does
" *text* stay italic? The outer --not-a-term vim cannot resolve syn names
" (see note above), but a nested `vim -es` CAN. So we extract the plugin's own
" `syn`/`hi def link` PiMd* lines verbatim from the real plugin file (their
" definition order is exactly what decides the bold/italic precedence) and dump
" the per-byte resolved names for two probe lines.
function! s:RenderCheck()
    let l:cmds = []
    for l:ln in readfile(s:root . '/plugin/pi_chat.vim')
        if l:ln =~# '^\s*syn \(match\|region\) PiMd\|^\s*hi def link PiMd'
            call add(l:cmds, substitute(l:ln, '^\s*', '', ''))
        endif
    endfor
    call writefile(['x **README** y', 'x *readme* y'], '/tmp/t-markdown-probe.txt')
    " NOTE: the inner script must NOT run `syntax enable` — on this build it
    " resets the just-defined items for a filetype-less .txt buffer and kills
    " the highlighting. Plain syn items work without it.
    call writefile(['edit /tmp/t-markdown-probe.txt'] + l:cmds + [
                \ 'redir! > /tmp/t-markdown-render.txt',
                \ 'for s:ln in [1, 2]',
                \ '  let s:n = []',
                \ '  for s:c in range(1, col("$") - 1)',
                \ '    call add(s:n, synIDattr(synID(s:ln, s:c, 1), "name"))',
                \ '  endfor',
                \ '  echo "L" . s:ln . ":" . join(s:n, ",")',
                \ 'endfor',
                \ 'redir END',
                \ 'qa!'], '/tmp/t-markdown-render.vim')
    let l:rc = system('vim -es -u NONE -c "source /tmp/t-markdown-render.vim" < /dev/null 2>&1')
    if l:rc != 0 || !filereadable('/tmp/t-markdown-render.txt')
        return 'render-harness-failed'
    endif
    let l:out = {}
    for l:ln in readfile('/tmp/t-markdown-render.txt')
        if l:ln =~# '^L[12]:'
            let l:out[l:ln[1]] = l:ln[3:]
        endif
    endfor
    if !has_key(l:out, '1') || !has_key(l:out, '2')
        return 'render-harness-failed'
    endif
    " **README**: the word must resolve to bold and must not be covered by the
    " italic item (the regression the user hit: **text** rendering italic).
    if l:out[1] !~# 'PiMdBold' || l:out[1] =~# 'PiMdItalic'
        return 'render-bold-was-italic'
    endif
    " *readme*: must remain italic (control: single-star emphasis intact).
    if l:out[2] !~# 'PiMdItalic' || l:out[2] =~# 'PiMdBold'
        return 'render-italic-broken'
    endif
    return 'render-ok'
endfunction

function! s:Check()
    let l:out = [
                \ 'markdown: ' . g:pi_chat_markdown,
                \ 'PiMdHeading: ' . s:GroupStatus('PiMdHeading', 'Title'),
                \ 'PiMdCode: ' . s:GroupStatus('PiMdCode', 'Special'),
                \ 'PiMdList: ' . s:GroupStatus('PiMdList', 'Keyword'),
                \ s:RenderCheck(),
                \ ]
    call writefile(l:out, '/tmp/t-markdown.txt')
    execute 'qall!'
endfunction

" PiOpen (runs s:BufSetup -> s:ApplyMarkdown, defining the items) then check.
call timer_start(300, { -> execute('silent! PiOpen') })
call timer_start(2000, { -> s:Check() })
