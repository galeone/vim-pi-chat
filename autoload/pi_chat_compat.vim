" pi_chat_compat.vim — Vim/Neovim job/channel compatibility shim
"
" Wraps Vim's job_start/ch_sendraw/job_stop/job_status/ch_close/job_info and
" Neovim's jobstart/chansend/jobstop/chanclose behind a single API so
" plugin/pi_chat.vim works on both editors unchanged.

let s:is_nvim = has('nvim')

" Neovim state: maps job_id -> { alive, pid, stdout_buf, stderr_buf,
"                                 out_cb, err_cb, exit_cb }
let s:nvim_jobs = {}

" ----------------------------- public API ----------------------------------

function! pi_chat_compat#JobStart(cmd, vim_opts) abort
  if !s:is_nvim
    return job_start(a:cmd, a:vim_opts)
  endif

  let l:state = {
        \ 'alive': 1,
        \ 'pid': -1,
        \ 'stdout_buf': '',
        \ 'stderr_buf': '',
        \ 'out_cb': get(a:vim_opts, 'out_cb', v:null),
        \ 'err_cb': get(a:vim_opts, 'err_cb', v:null),
        \ 'exit_cb': get(a:vim_opts, 'exit_cb', v:null),
        \ }

  let l:opts = {
        \ 'on_stdout': function('s:NvimOnStdout'),
        \ 'on_stderr': function('s:NvimOnStderr'),
        \ 'on_exit': function('s:NvimOnExit'),
        \ }
  if has_key(a:vim_opts, 'cwd')
    let l:opts.cwd = a:vim_opts.cwd
  endif

  let l:job_id = jobstart(a:cmd, l:opts)
  if l:job_id <= 0
    return l:job_id
  endif

  try
    let l:state.pid = jobpid(l:job_id)
  catch
  endtry
  let s:nvim_jobs[l:job_id] = l:state
  return l:job_id
endfunction

function! pi_chat_compat#JobStop(job) abort
  if !s:is_nvim
    call job_stop(a:job)
    return
  endif
  if has_key(s:nvim_jobs, a:job)
    let s:nvim_jobs[a:job].alive = 0
  endif
  try
    call jobstop(a:job)
  catch
  endtry
endfunction

function! pi_chat_compat#JobAlive(job) abort
  if !s:is_nvim
    return job_status(a:job) ==# 'run'
  endif
  return has_key(s:nvim_jobs, a:job) && s:nvim_jobs[a:job].alive
endfunction

function! pi_chat_compat#JobPid(job) abort
  if !s:is_nvim
    try
      return get(job_info(a:job), 'process', -1)
    catch
      return -1
    endtry
  endif
  if has_key(s:nvim_jobs, a:job)
    return s:nvim_jobs[a:job].pid
  endif
  return -1
endfunction

function! pi_chat_compat#ChSend(job, data) abort
  if !s:is_nvim
    call ch_sendraw(a:job, a:data)
    return
  endif
  call chansend(a:job, a:data)
endfunction

function! pi_chat_compat#ChClose(job) abort
  if !s:is_nvim
    call ch_close(a:job)
    return
  endif
  try
    call chanclose(a:job, 'stdin')
  catch
  endtry
endfunction

function! pi_chat_compat#IsJob(val) abort
  if !s:is_nvim
    return type(a:val) == v:t_job
  endif
  return type(a:val) == v:t_number && a:val > 0 && has_key(s:nvim_jobs, a:val)
endfunction

" ----------------------- Neovim callback internals -------------------------

" Neovim's on_stdout delivers a List of strings split on \n. The last element
" is the incomplete trailing piece (empty string '' if the chunk ended on a
" newline). The next callback's first element continues that leftover.
"
" We reassemble complete lines and call the original out_cb(job_id, line) one
" line at a time, matching Vim's out_mode='nl' behavior.

function! s:NvimOnStdout(job_id, data, event) abort
  let l:st = get(s:nvim_jobs, a:job_id, v:null)
  if l:st is v:null | return | endif
  if l:st.out_cb is v:null | return | endif

  let a:data[0] = l:st.stdout_buf . a:data[0]
  let l:last = len(a:data) - 1
  let l:i = 0
  while l:i < l:last
    call l:st.out_cb(a:job_id, a:data[l:i])
    let l:i += 1
  endwhile
  let l:st.stdout_buf = a:data[l:last]
endfunction

function! s:NvimOnStderr(job_id, data, event) abort
  let l:st = get(s:nvim_jobs, a:job_id, v:null)
  if l:st is v:null | return | endif
  if l:st.err_cb is v:null | return | endif

  let a:data[0] = l:st.stderr_buf . a:data[0]
  let l:last = len(a:data) - 1
  let l:i = 0
  while l:i < l:last
    call l:st.err_cb(a:job_id, a:data[l:i])
    let l:i += 1
  endwhile
  let l:st.stderr_buf = a:data[l:last]
endfunction

function! s:NvimOnExit(job_id, code, event) abort
  let l:st = get(s:nvim_jobs, a:job_id, v:null)
  if l:st is v:null | return | endif

  " Flush any remaining buffered output before signaling exit.
  if !empty(l:st.stdout_buf) && l:st.out_cb isnot v:null
    call l:st.out_cb(a:job_id, l:st.stdout_buf)
    let l:st.stdout_buf = ''
  endif
  if !empty(l:st.stderr_buf) && l:st.err_cb isnot v:null
    call l:st.err_cb(a:job_id, l:st.stderr_buf)
    let l:st.stderr_buf = ''
  endif

  let l:st.alive = 0
  if l:st.exit_cb isnot v:null
    call l:st.exit_cb(a:job_id, a:code)
  endif
endfunction
