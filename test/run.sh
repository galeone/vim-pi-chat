#!/bin/sh
# Headless test runner for vim-pi-chat.
#
# Every test drives the REAL plugin (plugin/pi_chat.vim) through its public
# commands (:PiOpen, :PiFile, :PiClear, the <CR> send mapping) against the
# deterministic test/fake-pi.js (selected because PATH points at test/). A
# scenario is a tiny vimrc in test/scenarios/ that opens the chat, sends
# prompts, and dumps the chat buffer to /tmp/t-<name>.txt when it is done; the
# runner then greps that dump for the lines the scenario is meant to produce
# and asserts the run had zero Vim E-errors.
#
# Usage:
#   PATH="$PWD/test:$PATH" sh test/run.sh            # run everything
#   PATH="$PWD/test:$PATH" sh test/run.sh think      # run just t-think
#   FAKE_PI_DELAY_MS=200 FAKE_PI_TURN_MS=60 sh test/run.sh   # faster
set -u
cd "$(dirname "$0")/.."
export PATH="$PWD/test:$PATH"   # so job_start(['pi',...]) finds test/pi -> fake-pi.js

# Allow overriding the editor: VIM=nvim sh test/run.sh
VIM="${VIM:-vim}"
export FAKE_PI_DELAY_MS="${FAKE_PI_DELAY_MS:-300}"
export FAKE_PI_TURN_MS="${FAKE_PI_TURN_MS:-60}"
export FAKE_PI_THINKING="${FAKE_PI_THINKING:-}"
export FAKE_PI_TOOL="${FAKE_PI_TOOL:-}"
export FAKE_PI_NOTIFY_ALL="${FAKE_PI_NOTIFY_ALL:-}"

PASS=0; FAIL=0; FAILED=""
note() { printf '%s\n' "$*"; }
record() { # record <name> <1|0> <detail>
  if [ "$2" = 1 ]; then PASS=$((PASS+1)); note "PASS  $1"
  else FAIL=$((FAIL+1)); FAILED="$FAILED $1"; note "FAIL  $1  $3"; fi
}
# Vim E-error count for a run log (ANSI stripped).
# Neovim's headless -u mode triggers E484 for missing syntax.vim; filter it.
pe() { sed 's/\x1b\[[0-9;]*m//g' "/tmp/run-$1.log" 2>/dev/null | grep -vE "E484:.*syntax.vim" | grep -cE 'E[0-9]+:'; }
has() { grep -qE -- "$2" "/tmp/t-$1.txt" 2>/dev/null; }
nmatch() { grep -cE -- "$2" "/tmp/t-$1.txt" 2>/dev/null; }

FP="$PWD/test:$PATH"
# run <name> <sleep_s> : launch a scenario, wait past its dump timer, capture.
run() {
  rm -f "/tmp/t-$1.txt" "/tmp/run-$1.log"
  # sleep keeps vim's stdin open for $2 s (headless vim exits on stdin EOF);
  # when the sleep finishes the pipe EOFs and terminates vim. Blocks exactly
  # $2 s and always returns, so the suite can never hang on a scenario.
  if [ "$VIM" = "nvim" ]; then
    sleep "$2" | nvim --headless -u "./test/scenarios/t-$1.vim" > "/tmp/run-$1.log" 2>&1
  else
    sleep "$2" | vim --not-a-term -Nu "./test/scenarios/t-$1.vim" > "/tmp/run-$1.log" 2>&1
  fi
}
# check <name> <want-regex> [forbid-regex] [min-two-regex]
check() {
  name=$1; ok=1; detail=""
  [ "$(pe "$name")" -gt 0 ] && { ok=0; detail="Vim E-errors present"; }
  if [ -n "${2:-}" ]; then has "$name" "$2" || { ok=0; detail="${detail} missing: $2"; }; fi
  if [ -n "${3:-}" ]; then has "$name" "$3" && { ok=0; detail="${detail} should not contain: $3"; }; fi
  if [ -n "${4:-}" ]; then [ "$(nmatch "$name" "$4")" -ge 2 ] || { ok=0; detail="${detail} expected >=2 of: $4"; }; fi
  # Optional 5th/6th args: regex that must match exactly N times (N defaults 1).
  if [ -n "${5:-}" ]; then
    c=$(grep -cE -- "$5" "/tmp/t-$name.txt" 2>/dev/null); c=${c:-0}
    [ "$c" -eq "${6:-1}" ] || { ok=0; detail="${detail} expected exactly ${6:-1} of: $5 (got $c)"; }
  fi
  if [ "$ok" = 0 ]; then note "      --- dump ---"; sed 's/^/        /' "/tmp/t-$name.txt" 2>/dev/null; fi
  record "$name" "$ok" "$detail"
}

only="${1:-}"

# ---- basic single-open E2E (the original test/vimrc-test) ----
if [ -z "$only" ] || [ "$only" = basic ]; then
  rm -f /tmp/pibuf.txt /tmp/pilog.txt /tmp/pistatus.txt
  if [ "$VIM" = "nvim" ]; then
    sleep 11 | nvim --headless -u ./test/vimrc-test > /tmp/pilog.txt 2>&1
  else
    sleep 11 | vim --not-a-term -Nu ./test/vimrc-test > /tmp/pilog.txt 2>&1
  fi
  sleep 0.3
  ok=1
  [ "$(sed 's/\x1b\[[0-9;]*m//g' /tmp/pilog.txt 2>/dev/null | grep -vE 'E484:.*syntax.vim' | grep -cE 'E[0-9]+:')" -gt 0 ] && ok=0
  for s in 'Echo: hello fake' '✓ bash' 'fake reply to: hello fake'; do
    grep -qE "$s" /tmp/pibuf.txt 2>/dev/null || ok=0
  done
  [ "$(grep -c 'Press ENTER' /tmp/pilog.txt 2>/dev/null)" -gt 0 ] && ok=0
  if [ "$ok" = 0 ]; then note "      --- dump ---"; sed 's/^/        /' /tmp/pibuf.txt 2>/dev/null; fi
  record basic "$ok" "check /tmp/pibuf.txt + /tmp/pilog.txt"
fi

# ---- scenarios (each t-*.vim in test/scenarios) ----
for f in test/scenarios/t-*.vim; do
  [ -e "$f" ] || continue
  name=$(basename "$f" .vim); name=${name#t-}
  [ -n "$only" ] && [ "$only" != "$name" ] && continue
  case "$name" in
    abort)    export FAKE_PI_THINKING= FAKE_PI_TOOL=;     run abort 4;   check abort 'abort requested' '' '' ;;
    abortresume) export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_DELAY_MS=800 FAKE_PI_TURN_MS=1200
                 run abortresume 10
                 check abortresume 'abort requested' '' ''
                 # the post-abort prompt (sent through the normal CR path) must
                 # still reach the agent and get a reply
                 check abortresume 'Echo: second prompt' '' ''
                 export FAKE_PI_DELAY_MS=300 FAKE_PI_TURN_MS=60 ;;
    abortreplay)
                 # replay of a captured REAL pi session: in-flight tool, abort
                 # mid-tool (real event flood), then a follow-up prompt
                 export PATH="$PWD/test/replay/bin:$PATH"
                 run abortreplay 14
                 export PATH="$PWD/test:$PATH"
                 check abortreplay 'abort requested' '' ''
                 check abortreplay '^OK$' '' '' ;;
    abortdeath)
                 # pi dies right after the abort burst (stale-ctx style
                 # extension crash); the panel must be recoverable with
                 # :PiOpen and a later send must reach the new process
                 rm -f /tmp/t-abortdeath-state
                 export REPLAY_DIE_AFTER_ABORT=1 REPLAY_STATE=/tmp/t-abortdeath-state
                 export PATH="$PWD/test/replay/bin:$PATH"
                 run abortdeath 16
                 export REPLAY_DIE_AFTER_ABORT= REPLAY_STATE=
                 export PATH="$PWD/test:$PATH"
                 # the dead-agent warning appears exactly once and no stuck
                 # "pi is working" spinner line may remain in the buffer
                 check abortdeath 'agent process is not running' '⏳ pi is working' '' 'agent process is not running' 1
                 check abortdeath '^OK$' '' '' ;;
    close)    export FAKE_PI_THINKING= FAKE_PI_TOOL=;     run close 4
              check close 'wins:1' '' ''
              check close 'bufwinnr:-1' '' '' ;;
    fail)     export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_TOOLFAIL=1
              run fail 4
              check fail '✗ bash failed' '' ''
              export FAKE_PI_TOOLFAIL= ;;
    nosession) export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_ARGV_LOG=/tmp/fakepi-argv.log
              run nosession 5
              check nosession '--no-session' '' ''
              export FAKE_PI_ARGV_LOG= ;;
    pifilecmd) export FAKE_PI_THINKING= FAKE_PI_TOOL=;     run pifilecmd 4
              check pifilecmd 'context file: .*pi_chat.vim' '' '' ;;
    pisend)   export FAKE_PI_THINKING= FAKE_PI_TOOL=;     run pisend 3
              check pisend 'Echo: pi send test' '' '' ;;
    reload)   export FAKE_PI_THINKING= FAKE_PI_TOOL=write FAKE_PI_EDIT_PATH=/tmp/t-reload-ctx.txt
               export FAKE_PI_WRITE_CONTENT="$(printf 'alpha\nzqx7k-new\nbeta\n')"
               run reload 12
               # shrank 5 -> 3 lines: the open buffer must show exactly the new
               # content (old tail lines gone) and not be left modified
               check reload 'BUF\[alpha\|zqx7k-new\|beta\] MOD\[0\]' 'BUF\[.*zqx7k-old' ''
               # ... and Vim knows the new timestamp (no W11 later)
               check reload 'STALE\[0\]' '' ''
               export FAKE_PI_WRITE_CONTENT= FAKE_PI_EDIT_PATH= ;;
    diskchg)  export FAKE_PI_THINKING= FAKE_PI_TOOL=bash
               # The fake really runs this command: it rewrites the tracked
               # context file on disk from a NON edit/write tool.
               # POSIX rewrite (BSD-only 'sed -i ''' breaks GNU sed on Linux CI):
               # the file is exactly these four lines, line 2 flipped to the new marker.
               export FAKE_PI_BASH_CMD="printf 'alpha\nzqx7k-new\nbeta\ndelta\n' > /tmp/t-diskchg-ctx.txt"
               run diskchg 12
               # the open buffer shows the sed'd content, unmodified, and the
               # chat notes the external change
               check diskchg 'reloaded t-diskchg-ctx\.txt \(changed on disk\)' 'BUF\[.*zqx7k-old' ''
               check diskchg 'BUF\[alpha\|zqx7k-new\|beta\|delta\] MOD\[0\]' '' ''
               export FAKE_PI_BASH_CMD= ;;
    think)    export FAKE_PI_THINKING=1 FAKE_PI_TOOL=;    run think 10;  check think 'Thinking:' '' '' ;;
    thinkoff) export FAKE_PI_THINKING=1 FAKE_PI_TOOL=;    run thinkoff 10; check thinkoff 'Echo:' 'Thinking:' '' ;;
    thinkpanel) export FAKE_PI_THINKING=1 FAKE_PI_TOOL=
                # multi-line thinking text so the auto-scroll assertion is real
                export FAKE_PI_THINKING_TEXT="Thinking: weighing
the options, carefully
and then acting"
              run thinkpanel 10
              # panel buffer gets the (multi-line) thinking text, the chat
              # reply does not leak into it, and toggle off/on keeps and
              # restores the window
              check thinkpanel 'Thinking: weighing' 'Echo:' 'wins: 3'
              # panel is read-only (nomodifiable) and auto-scrolls to the
              # bottom: 4 rendered lines (prompt marker + 3 thinking lines),
              # cursor parked on line 4
              check thinkpanel 'mod: 0' '' ''
              check thinkpanel 'cur: 4/4' '' ''
              # per-turn prompt marker keeps the thinking history visible
              check thinkpanel '──── think about it' '' '' ;;
    tools)    export FAKE_PI_THINKING= FAKE_PI_TOOL=multi; run tools 13;  check tools '✓ edit' '' '' ;;
    diffedit)  export FAKE_PI_THINKING= FAKE_PI_TOOL=edit FAKE_PI_EDIT_PATH=/tmp/t-diffedit-ctx.txt
               # marker strings keep the check immune to the resumed session
               # transcript (scenarios replay the real pi session of this repo)
               export FAKE_PI_DIFF="$(printf '   1 alpha\n-  2 zqx7k-old\n+  2 zqx7k-new\n   3 delta')"
               run diffedit 10
               # the fake edit carries a canned pi display diff (w=2 numbering);
               # it must render indented above the ✓ line
               check diffedit '    1 alpha' '' ''
               check diffedit '  -  2 zqx7k-old' '' ''
               check diffedit '  \+  2 zqx7k-new' '' ''
               check diffedit '✓ edit' '' ''
               export FAKE_PI_DIFF= ;;
    diffwrite) export FAKE_PI_THINKING= FAKE_PI_TOOL=write FAKE_PI_EDIT_PATH=/tmp/t-diffwrite-ctx.txt
               export FAKE_PI_WRITE_CONTENT="$(printf 'zqx7k-ctx\nGAMMA\nbeta\nzeta\nzqx7k-new\neta\ntheta\n')"
               run diffwrite 12
               # write args carry the new content; the on-disk old content
               # (written by the scenario) must show as - lines, new as + lines.
               # The context line is indented 2 + ' N ' (single-digit width),
               # hence exactly 3 leading spaces.
               check diffwrite '   1 zqx7k-ctx' '' ''
               check diffwrite '  -3 zqx7k-old' '' ''
               check diffwrite '  \+5 zqx7k-new' '' ''
               check diffwrite '✓ write' '' ''
               export FAKE_PI_WRITE_CONTENT= ;;
    diffoff)   export FAKE_PI_THINKING= FAKE_PI_TOOL=multi FAKE_PI_EDIT_PATH=/tmp/t-diffedit-ctx.txt
               export FAKE_PI_DIFF="$(printf '   1 alpha\n-  2 zqx7k-old\n+  2 zqx7k-new\n   3 delta')"
               run diffoff 15
               # g:pi_chat_tool_diff=0: the edit still completes but no diff
               check diffoff '✓ edit' '  -  2 zqx7k-old' ''
               export FAKE_PI_DIFF= FAKE_PI_EDIT_PATH= ;;
    multi)    export FAKE_PI_THINKING= FAKE_PI_TOOL=;     run multi 10;  check multi '' '' 'Echo:' ;;
    markdown) export FAKE_PI_THINKING= FAKE_PI_TOOL=
              run markdown 6
              # s:ApplyMarkdown must define each PiMd* group, link it to the right
              # target, AND create a real syn match/region item for it (want a
              # sample fully-ok, forbid absent/mismatch/item-missing, want >=2 ok).
              # Headless: synID rendering is a no-op, but :hi + :syntax list are
              # observable; the item check catches syn lines that silently fail.
              # 'render-ok' (nested vim -es per-byte dump) proves **text** resolves
              # to bold, not italic; the forbid list also catches the render
              # failure strings (which the plain ': ok' min-two would not).
              check markdown 'PiMdHeading: ok' 'absent\|mismatch\|item-missing\|render-harness\|render-bold\|render-italic' ': ok' 'render-ok' '1' ;;
    stress)   export FAKE_PI_THINKING=1 FAKE_PI_TOOL=
              # ~1000 thinking lines (~49KB) => ~49k one-char
              # thinking_delta frames.  Pre-fix (per-delta panel work) this is
              # minutes of O(n^2) work and the run never drains; post-fix the
              # drain is linear, ~8k frames/s on a slow CI runner (~6s), so the
              # panel head/tail and the echo reply must all be present when the
              # dump is taken.  Kept well under the 18.5s dump deadline: the
              # rate is bound by per-frame json_decode, i.e. by machine speed.
              # Via a file, not FAKE_PI_THINKING_TEXT: Linux caps a single
              # env string at 128KB (MAX_ARG_STRLEN), and an oversized export
              # makes every later exec (rm, sleep, grep) fail with E2BIG.
              seq 1 1000 | awk '{printf "reasoning step %04d with enough padding to matter\n", $1}' > /tmp/t-stress-think.txt
              export FAKE_PI_THINKING_FILE=/tmp/t-stress-think.txt
              run stress 22
              check stress 'PANELHEAD ──── think about it' '' ''
              check stress 'PANELTAIL reasoning step 1000' '' ''
              check stress 'CHATTAIL Echo: think about it' '' ''
              check stress '^PANELCOUNT 1001$' '' '' '' '^PANELCOUNT 1001$'
              export FAKE_PI_THINKING_FILE= ;;
    busyhop)  export FAKE_PI_DELAY_MS=8000 FAKE_PI_THINKING= FAKE_PI_TOOL=
              run busyhop 6
              # ~2.5s busy with nothing queued: zero autocmd firings (the old
              # per-tick window hop fired ~100 of each), the spinner still
              # advanced, and its status stayed on the chat buffer.
              check busyhop '^HOPS 0 0 0$' '' ''
              check busyhop '^SPIN 1$' '' ''
              check busyhop '^FILESTATUS $' '' ''
              check busyhop '^CUR t-busyhop-file\.txt$' '' ''
              export FAKE_PI_DELAY_MS= ;;
    settlestatus) export FAKE_PI_DELAY_MS=1500 FAKE_PI_THINKING= FAKE_PI_TOOL=
              run settlestatus 7
              # turn settled ~2s before the dump, no keystroke since: the
              # painted status line must say 'pi chat', not a spinner frame.
              check settlestatus '^VAR pi chat$' '' ''
              check settlestatus '^SCREEN ?pi chat ' 'working|contacting' ''
              export FAKE_PI_DELAY_MS= ;;
    working)  export FAKE_PI_DELAY_MS=2500 FAKE_PI_TURN_MS=100 FAKE_PI_THINKING= FAKE_PI_TOOL=
              run working 7
              # in flight: working line shown, reply not yet; after settle: reply in, working gone.
              check working-mid 'pi is working' 'Echo:' ''
              check working 'Echo: hello fake' 'pi is working' ''
              export FAKE_PI_DELAY_MS= ;;
    clear)    export FAKE_PI_THINKING=1 FAKE_PI_TOOL= FAKE_PI_ARGV_LOG=/tmp/t-clear-argv.log
              : > /tmp/t-clear-argv.log
              run clear 13
              # The seeded pre-clear session file must be deleted by :PiClear,
              # so a later :PiOpen (even after a vim restart) resumes the
              # post-clear session instead of the pre-clear one.
              check clear 'Echo: second' 'Echo: first' '' 'cleared-old: 1'
              # :PiClear must also wipe the thinking panel: only the second
              # turn's marker may remain, the first turn's must be gone.  (grep
              # the scenario's dump directly: check() would look for a file
              # named after this check.)
              if grep -qE -- '──── second question' /tmp/t-clear.txt && ! grep -qE -- '──── first question' /tmp/t-clear.txt; then
                record clear-think 1 ''
              else
                record clear-think 0 'thinking panel not cleared (first turn lingered or second turn missing)'
              fi
              # :PiClear must restart the process rather than send an in-process
              # `new_session` (session replacement leaves pi-observational-memory
              # holding a stale ctx; it then throws on the next settled turn and
              # exits the agent with code 1).  The restart reuses the stable
              # context-keyed id (the pre-clear file is deleted first, so
              # create-or-resume starts a fresh session), so both launches must
              # carry the same --session-id.
              if node -e 'const fs=require("fs");const l=fs.readFileSync("/tmp/t-clear-argv.log","utf8").trim().split("\n").filter(Boolean).map(s=>JSON.parse(s));const id=a=>{const i=a.indexOf("--session-id");return i<0?null:a[i+1];};if(l.length!==2)throw new Error("expected 2 launches, got "+l.length);if(!id(l[0])||!id(l[1]))throw new Error("missing --session-id in launch");if(id(l[0])!==id(l[1]))throw new Error("PiClear restart must keep the context-keyed session id");' 2>/dev/null
              then record clear-restart 1
              else record clear-restart 0 "restart with context-keyed --session-id not observed"
              fi
              export FAKE_PI_ARGV_LOG= ;;
    pifile)   export FAKE_PI_THINKING= FAKE_PI_TOOL=;     run pifile 6;  check pifile 'context file: .*t-pifile-ctx' '' '' ;;
    notify)   export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_NOTIFY_ALL=1
              run notify 4
              check notify 'ℹ info note' '' ''
              check notify '⚠ warn note' '' ''
              check notify '⛔ error note' '' ''
              export FAKE_PI_NOTIFY_ALL= ;;
    notifycursor) export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_LATE_NOTIFY_MS=800
                  run notifycursor 6
                  # the late notify renders in the log, and the cursor stays
                  # where the user typed (col 8, after 'abc') instead of being
                  # yanked back to col 5 (right after '❯ ') by the drain tick
                  check notifycursor 'ℹ late note' 'CURSOR [0-9]*:5' ''
                  check notifycursor 'CURSOR [0-9]*:8' '' ''
                  export FAKE_PI_LATE_NOTIFY_MS= ;;
    cursorprompt) export FAKE_PI_THINKING= FAKE_PI_TOOL=
                  run cursorprompt 5
                  # after the reply settles, the cursor must rest AFTER the ❯
                  # marker (byte col strlen('❯ ')+1 on a bare '❯ ' line), not in
                  # front of it: the glyph is blanked while pi works (cursor
                  # clamps to byte col 1) and HideWorking puts '❯ ' back with no
                  # cursor move, so the drain tick's s:StickToInput must re-anchor
                  # after the turn settles: input is '❯ ' with the cursor behind it (byte col 5,
                  # where the first typed char lands) — never in front of the glyph
                  check cursorprompt 'CURSOR [0-9]+:5 LAST=[0-9]+ OK' 'CURSOR [0-9]*:1 LAST= BAD' ;;
    modelstatus) export FAKE_PI_THINKING= FAKE_PI_TOOL=
                  run modelstatus 5
                  # the statusline right segment must show the model from pi's
                  # get_state response (fake: provider 'fake', id 'pi-test');
                  # s:Final dumps PiChatStatusModel() as a 'MODEL …' line
                  check modelstatus 'Echo: hello' '' ''
                  check modelstatus 'MODEL fake/pi-test' 'MODEL *$' ''
                  ;;
    blankgap) export FAKE_PI_THINKING= FAKE_PI_TRAILING_NEWLINES=2
              run blankgap 5
              # model text 'Echo: hello\n\n' must not balloon the gap before
              # the tool line: at most ONE consecutive blank line anywhere in
              # the buffer (pre-fix the trailing \n\n + tail placeholder +
              # turn separator stacked to 3 blanks between text and tool)
              check blankgap 'Echo: hello' '' ''
              check blankgap '  ⚙ bash' '' ''
              check blankgap 'BLANK MAX=1' 'BLANK MAX=[2-9]' ''
              export FAKE_PI_TRAILING_NEWLINES= ;;
    restart)  export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_ARGV_LOG=/tmp/t-restart-argv.log
              : > /tmp/t-restart-argv.log
              run restart 6
              # :PiRestart must keep the transcript (both replies survive) and
              # must NOT start a new session or wipe the log
              check restart 'Echo: first' 'new session' ''
              check restart 'pi process restarted' '' ''
              check restart 'Echo: second' '' ''
              # both launches must carry the SAME --session-id (resume, not new)
              if node -e 'const fs=require("fs");const l=fs.readFileSync("/tmp/t-restart-argv.log","utf8").trim().split("\n").filter(Boolean).map(s=>JSON.parse(s));const id=a=>{const i=a.indexOf("--session-id");return i<0?null:a[i+1];};if(l.length!==2)throw new Error("expected 2 launches, got "+l.length);if(!id(l[0])||!id(l[1]))throw new Error("missing --session-id in launch");if(id(l[0])!==id(l[1]))throw new Error("PiRestart must resume the same session id");' 2>/dev/null
              then record restart-argv 1
              else record restart-argv 0 "same-session restart not observed in argv log"
              fi
              export FAKE_PI_ARGV_LOG= ;;
    paralleltools) export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_PARALLEL=1
              export FAKE_PI_EDIT_PATH=/tmp/t-paralleltools-a.txt FAKE_PI_EDIT_PATH2=/tmp/t-paralleltools-b.txt
              run paralleltools 5
              # overlapping tool calls: BOTH open buffers are reloaded
              check paralleltools 'A\[parallel-A\]' 'A\[old-A\]' ''
              check paralleltools 'B\[parallel-B\]' 'B\[old-B\]' ''
              export FAKE_PI_PARALLEL= FAKE_PI_EDIT_PATH= FAKE_PI_EDIT_PATH2= ;;
    resumefmt) export FAKE_PI_THINKING= FAKE_PI_TOOL=
              run resumefmt 4
              # replayed prompts show what was typed (prefix stripped) ...
              check resumefmt '^CHAT ❯ first question$' 'The file I am working on\|❯ I switched' ''
              check resumefmt '^CHAT ❯ second question$' '' ''
              check resumefmt '^CHAT with two lines$' '' ''
              check resumefmt 'blank-before-first: 1' '' ''
              # ... an old bare switch notice is a log line, not a prompt ...
              check resumefmt '^CHAT pi-chat: context file switched: /x/g\.txt$' '' ''
              # ... and the abandoned branch stays hidden (chat and panel)
              check resumefmt '^CHAT second answer$' 'abandoned' ''
              check resumefmt '^PANEL ──── second question with two lines$' '' ''
              check resumefmt '^PANEL kept thought$' '' '' ;;
    stash)    export FAKE_PI_THINKING= FAKE_PI_TOOL=none
              run stash 5
              # :PiSend from a file window never touches the file ...
              check stash 'file-intact: 1' '' ''
              check stash 'sent-in-chat: 1' '' ''
              # ... and the half-typed draft is back after the turn and after
              # a park + reopen
              check stash 'settled TAIL\[❯ draft text\|draft line two\]' '' ''
              check stash 'reopened TAIL\[❯ draft text\|draft line two\]' '' '' ;;
    toolout)  export FAKE_PI_THINKING= FAKE_PI_TOOL=multi FAKE_PI_EDIT_PATH=/tmp/t-toolout-ctx.txt
              export FAKE_PI_TOOL_OUTPUT="$(printf 'out1\nout2\nout3\nout4\nout5\nout6\nout7\nout8\n')"
              run toolout 5
              # bash: first 5 output lines + a count of the rest; exactly one
              # output block (read/edit output is not shown)
              check toolout '^    │ out5$' '^    │ out6$' '' '^    │ out1$' 1
              check toolout '^    │ … 3 more lines$' '' ''
              export FAKE_PI_TOOL_OUTPUT= FAKE_PI_EDIT_PATH= ;;
    tooloutfail) export FAKE_PI_THINKING= FAKE_PI_TOOL=multi FAKE_PI_TOOLFAIL=1 FAKE_PI_EDIT_PATH=/tmp/t-toolout-ctx.txt
              export FAKE_PI_TOOL_OUTPUT="$(printf 'bash: frobnicate: command not found\n')"
              run tooloutfail 5
              # a failed tool shows its error output right under the ✗ line
              check tooloutfail '✗ bash failed' '' ''
              check tooloutfail '^    │ bash: frobnicate: command not found$' '' ''
              export FAKE_PI_TOOL_OUTPUT= FAKE_PI_TOOLFAIL= FAKE_PI_EDIT_PATH= ;;
    quitx)    export FAKE_PI_THINKING= FAKE_PI_TOOL=none
              run quitx 4
              # :x in the last real window closes the pi panels and exits Vim,
              # after writing the file
              check quitx '^EXITED$' 'STILL-RUNNING' ''
              check quitx 'panels-open: 1' '' ''
              if grep -qx 'edited then :x' /tmp/t-quitx-file.txt; then record quitx-saved 1
              else record quitx-saved 0 ':x did not write the file'; fi ;;
    quitkeep) export FAKE_PI_THINKING= FAKE_PI_TOOL=none
              run quitkeep 4
              check quitkeep 'split-q: running chat-visible=1' '' ''
              check quitkeep 'chat-q: running chat-visible=0 file-visible=1' '' ''
              check quitkeep 'only: running wins=1' '' '' ;;
    quitoff)  export FAKE_PI_THINKING= FAKE_PI_TOOL=none
              run quitoff 3
              check quitoff 'off-q: running chat-visible=1' '' '' ;;
    nldelta)  export FAKE_PI_THINKING= FAKE_PI_TOOL=none FAKE_PI_DELTAS='["Hello","\n\nWorld"," end"]'
              run nldelta 4
              # a delta starting with "\n" must not re-emit the text after it
              check nldelta '^World end$' '^World$' ''
              check nldelta '^Hello$' '' ''
              export FAKE_PI_DELTAS= ;;
    reject)   export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_REJECT='No API key for provider'
              run reject 4
              # a rejected prompt never settles: busy state must clear anyway
              check reject 'No API key for provider' '⏳ pi is working' ''
              check reject 'STATUS\[pi chat\]' '' ''
              check reject 'LAST\[❯ \]' '' ''
              export FAKE_PI_REJECT= ;;
    crash)    export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_CRASH_MS=200
              run crash 4
              # pi dies mid-turn: no stale working line, prompt restored
              check crash 'pi exited with code 1' '⏳ pi is working' ''
              check crash 'LAST\[❯ \]' '' ''
              check crash 'STATUS\[agent stopped\]' '' ''
              export FAKE_PI_CRASH_MS= ;;
    queue)    export FAKE_PI_THINKING= FAKE_PI_TOOL=none FAKE_PI_QUEUE=1 FAKE_PI_DELAY_MS=500
              run queue 6
              # :PiSend mid-turn: both replies land, ONE settle clears the
              # single working line, prompt and status are back to idle
              check queue 'Echo: first' '⏳ pi is working' ''
              check queue 'Echo: queued' '' ''
              check queue 'LAST\[❯ \]' '' ''
              check queue 'STATUS\[pi chat\]' '' ''
              export FAKE_PI_QUEUE= FAKE_PI_DELAY_MS=300 ;;
    park)     export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_LIFE_LOG=/tmp/t-park-life.log
              run park 6
              # the first close parks; each reopen runs exactly one pi
              check park 'parked1 ALIVE=0' '' ''
              check park 'reopened1 ALIVE=1' '' ''
              check park 'parked2 ALIVE=0' '' ''
              check park 'final ALIVE=1 LAUNCHES=3' '' ''
              check park 'header-kept: 1' '' ''
              export FAKE_PI_LIFE_LOG= ;;
    sessionid) export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_ARGV_LOG=/tmp/t-sessionid-argv.log
              run sessionid 4
              check sessionid 'launches: 3' '' ''
              check sessionid 'distinct-ab: 1' '' ''
              check sessionid 'stable-a: 1' '' ''
              check sessionid 'valid-ids: 1' '' ''
              export FAKE_PI_ARGV_LOG= ;;
    cleardir) export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_ARGV_LOG=/tmp/t-cleardir-argv.log
              run cleardir 4
              # :PiClear keeps the inherited folder session, re-keys the file
              check cleardir 'resumed-dir: 1' '' ''
              check cleardir 'clear-id-is-file: 1' '' ''
              check cleardir 'dir-session-kept: 1' '' ''
              export FAKE_PI_ARGV_LOG= ;;
    clearwipe) export FAKE_PI_THINKING= FAKE_PI_TOOL=none
              run clearwipe 5
              # :PiClear deletes the old log instead of blanking it
              check clearwipe 'FIRST\[pi chat: new session\]' 'BLANK MAX=[2-9]' ''
              check clearwipe 'BLANK MAX=1' 'Echo: first turn' '' ;;
    closethink) export FAKE_PI_THINKING=1 FAKE_PI_TOOL=none FAKE_PI_THINKING_TEXT=OLDTHOUGHT
              run closethink 5
              # :PiClose wipes the panel; reopening shows none of its thinking
              # (and raises no E21 - the runner fails on any E-error)
              check closethink 'first: OLDTHOUGHT' 'reopened: .*OLDTHOUGHT' ''
              check closethink 'after-close listed-or-exists=0' '' ''
              export FAKE_PI_THINKING_TEXT= ;;
    dialogs)  export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_LOG=/tmp/t-dialogs-stdin.log
              run dialogs 4
              # replies carry the request id; Esc cancels (never picks);
              # placeholders are hints; fire-and-forget gets no reply
              check dialogs 'sel-esc-cancelled: 1' '' ''
              check dialogs 'sel-pick-value: Block' '' ''
              check dialogs 'sel-one-cancelled: 1' '' ''
              check dialogs 'conf-yes: \{"confirmed": *true\}' '' ''
              check dialogs 'conf-no: \{"confirmed": *false\}' '' ''
              check dialogs 'conf-esc: \{"cancelled": *true\}' '' ''
              check dialogs 'conf-text: "Clear session\?\\nAll messages will be lost\."' '' ''
              check dialogs 'in-text-value: \[abc\]' '' ''
              check dialogs 'in-empty-value: \[\]' '' ''
              check dialogs 'in-esc-cancelled: 1' '' ''
              check dialogs 'editor-cancelled: 1' '' ''
              check dialogs 'status-replied: 0' '' ''
              check dialogs 'status-shown: 1' '' ''
              check dialogs 'status-cleared: 1' '' ''
              check dialogs 'prompt-prefill: ❯ prefilled\|second line$' '' ''
              export FAKE_PI_LOG= ;;
    stall)    echo "[stall] manual-only: a slow fake (FAKE_PI_DELAY_MS>1s) triggers a headless hit-enter barrier."
              echo "[stall] Verify by hand: the status line shows 'pi run exceeded Ns - may be stuck'. Scenario: test/scenarios/t-stall.vim" ;;
    resume)   export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_ARGV_LOG=/tmp/fakepi-argv.log
              : > /tmp/fakepi-argv.log
              run resume 10
              # :PiOpen launches pi with --session-id pchat-… (path-keyed, create-or-resume)
              check resume 'session_id_match=1 pchat=1' '' ''
              export FAKE_PI_ARGV_LOG= ;;
    leak)     export FAKE_PI_THINKING=1 FAKE_PI_TOOL=
              export FAKE_PI_THINKING_TEXT="Thinking: weighing
the options, carefully"
              run leak 5
              # the reply must land in CHAT and the thinking must NOT leak into
              # it, even though the thinking panel was the current window while
              # the reply burst was drained (the old code raised E21 here too)
              check leak 'Echo: leak check prompt' 'Thinking:' '' ;;
    resumethink) export FAKE_PI_THINKING= FAKE_PI_TOOL=
              # hermetic session dir with prior turns carrying thinking; a fresh
              # :PiOpen resumes BOTH the chat transcript and the thinking panel
              run resumethink 6
              check resumethink 'session-file-exists: 1' '' ''
              check resumethink 'chat-resumed-marker: 1' '' ''
              check resumethink 'chat-transcript-1: 1' '' ''
              check resumethink 'chat-transcript-2: 1' '' ''
              check resumethink 'panel-open: [1-9]' '' ''
              check resumethink 'panel-thought-1: 1' '' ''
              check resumethink 'panel-thought-2: 1' '' ''
              check resumethink 'panel-marker-1: 1' '' ''
              check resumethink 'panel-marker-2: 1' '' '' ;;
    panelguard) export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_LOG=/tmp/fakepi-panelguard.log
      : > /tmp/fakepi-panelguard.log
      run panelguard 7
      check panelguard 'panel-ok: current window shows the chat buffer'
      check panelguard 'filewindow-ok:'
      check panelguard 'I switched the file I am working on to: /tmp/panel-b\.txt'
      check panelguard 'context file switched: /tmp/panel-b\.txt'
      export FAKE_PI_LOG= ;;

    trackfile) export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_LOG=/tmp/fakepi-trackfile.log
              : > /tmp/fakepi-trackfile.log
              run trackfile 8
              # switching files sends pi nothing by itself (no model turn) ...
              check trackfile 'PROMPTS-BEFORE-SEND=0' '' ''
              # ... the next prompt carries ONE notice, for the latest file only
              # (a was superseded), and the prompt after it carries none
              check trackfile '"message": *"I switched the file I am working on to: /tmp/t-trackfile-b\.txt' \
                '"message": *"I switched[^"]*t-trackfile-a' '' '"message": *"I switched the file' 1
              check trackfile '"message": *"second prompt"' '' ''
              check trackfile 'context file switched: /tmp/t-trackfile-b\.txt'
              export FAKE_PI_LOG= ;;
    *)        export FAKE_PI_THINKING= FAKE_PI_TOOL=;     run "$name" 10; check "$name" '' '' '' ;;
  esac
done

note ""
note "==========================================="
note "PASS=$PASS  FAIL=$FAIL"
[ -n "$FAILED" ] && note "failed:$FAILED"
[ "$FAIL" -eq 0 ]
