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
pe() { sed 's/\x1b\[[0-9;]*m//g' "/tmp/run-$1.log" 2>/dev/null | grep -cE 'E[0-9]+:'; }
has() { grep -qE -- "$2" "/tmp/t-$1.txt" 2>/dev/null; }
nmatch() { grep -cE -- "$2" "/tmp/t-$1.txt" 2>/dev/null; }

FP="$PWD/test:$PATH"
# run <name> <sleep_s> : launch a scenario, wait past its dump timer, capture.
run() {
  rm -f "/tmp/t-$1.txt" "/tmp/run-$1.log"
  # sleep keeps vim's stdin open for $2 s (headless vim exits on stdin EOF);
  # when the sleep finishes the pipe EOFs and terminates vim. Blocks exactly
  # $2 s and always returns, so the suite can never hang on a scenario.
  sleep "$2" | vim --not-a-term -Nu "./test/scenarios/t-$1.vim" > "/tmp/run-$1.log" 2>&1
}
# check <name> <want-regex> [forbid-regex] [min-two-regex]
check() {
  name=$1; ok=1; detail=""
  [ "$(pe "$name")" -gt 0 ] && { ok=0; detail="Vim E-errors present"; }
  if [ -n "${2:-}" ]; then has "$name" "$2" || { ok=0; detail="${detail} missing: $2"; }; fi
  if [ -n "${3:-}" ]; then has "$name" "$3" && { ok=0; detail="${detail} should not contain: $3"; }; fi
  if [ -n "${4:-}" ]; then [ "$(nmatch "$name" "$4")" -ge 2 ] || { ok=0; detail="${detail} expected >=2 of: $4"; }; fi
  if [ "$ok" = 0 ]; then note "      --- dump ---"; sed 's/^/        /' "/tmp/t-$name.txt" 2>/dev/null; fi
  record "$name" "$ok" "$detail"
}

only="${1:-}"

# ---- basic single-open E2E (the original test/vimrc-test) ----
if [ -z "$only" ] || [ "$only" = basic ]; then
  rm -f /tmp/pibuf.txt /tmp/pilog.txt /tmp/pistatus.txt
  sleep 11 | vim --not-a-term -Nu ./test/vimrc-test > /tmp/pilog.txt 2>&1
  sleep 0.3
  ok=1
  [ "$(sed 's/\x1b\[[0-9;]*m//g' /tmp/pilog.txt 2>/dev/null | grep -cE 'E[0-9]+:')" -gt 0 ] && ok=0
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
    close)    export FAKE_PI_THINKING= FAKE_PI_TOOL=;     run close 4
              check close 'wins:1' '' ''
              check close 'bufwinnr:-1' '' '' ;;
    fail)     export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_TOOLFAIL=1
              run fail 4
              check fail '✗ bash failed' '' ''
              export FAKE_PI_TOOLFAIL= ;;
    model)    export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_LOG=/tmp/fakepi-model.log
              : > /tmp/fakepi-model.log
              run model 5
              check model 'set_model' '' ''
              check model 'gpt-x' '' ''
              export FAKE_PI_LOG= ;;
    nosession) export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_ARGV_LOG=/tmp/fakepi-argv.log
              run nosession 5
              check nosession '--no-session' '' ''
              export FAKE_PI_ARGV_LOG= ;;
    pifilecmd) export FAKE_PI_THINKING= FAKE_PI_TOOL=;     run pifilecmd 4
              check pifilecmd 'context file: .*pi_chat.vim' '' '' ;;
    pisend)   export FAKE_PI_THINKING= FAKE_PI_TOOL=;     run pisend 3
              check pisend 'Echo: pi send test' '' '' ;;
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
    multi)    export FAKE_PI_THINKING= FAKE_PI_TOOL=;     run multi 10;  check multi '' '' 'Echo:' ;;
    working)  export FAKE_PI_DELAY_MS=2500 FAKE_PI_TURN_MS=100 FAKE_PI_THINKING= FAKE_PI_TOOL=
              run working 7
              # in flight: working line shown, reply not yet; after settle: reply in, working gone.
              check working-mid 'pi is working' 'Echo:' ''
              check working 'Echo: hello fake' 'pi is working' ''
              export FAKE_PI_DELAY_MS= ;;
    clear)    export FAKE_PI_THINKING= FAKE_PI_TOOL=;     run clear 11;  check clear 'Echo: second' 'Echo: first' '' ;;
    pifile)   export FAKE_PI_THINKING= FAKE_PI_TOOL=;     run pifile 6;  check pifile 'context file: .*t-pifile-ctx' '' '' ;;
    notify)   export FAKE_PI_THINKING= FAKE_PI_TOOL= FAKE_PI_NOTIFY_ALL=1
              run notify 4
              check notify 'ℹ info note' '' ''
              check notify '⚠ warn note' '' ''
              check notify '⛔ error note' '' ''
              export FAKE_PI_NOTIFY_ALL= ;;
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
    *)        export FAKE_PI_THINKING= FAKE_PI_TOOL=;     run "$name" 10; check "$name" '' '' '' ;;
  esac
done

note ""
note "==========================================="
note "PASS=$PASS  FAIL=$FAIL"
[ -n "$FAILED" ] && note "failed:$FAILED"
[ "$FAIL" -eq 0 ]
