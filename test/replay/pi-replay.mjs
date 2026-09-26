// Replay fake for vim-pi-chat: replays the EXACT byte-level protocol
// captured from a real `pi --mode rpc` session (see test/replay/*.jsonl):
//
//   prompt #1 -> turn1.jsonl   agent_start, thinking deltas, a bash tool call
//                              that is left IN FLIGHT (the "stuck" turn)
//   abort     -> abort.jsonl   the real post-abort flood:
//                              tool_execution_end(isError), message/turn end
//                              pairs, agent_end, agent_settled, response
//   prompt #2 -> turn2.jsonl   full follow-up turn ending in agent_settled
//
// The point of this fake is to catch plugin state-machine bugs that only
// appear against the real protocol (extra frames, ordering, payloads),
// which the hand-written test/fake-pi.js does not reproduce.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = path.dirname(fileURLToPath(import.meta.url));
let buf = '';
let prompts = 0;
const out = (o) => process.stdout.write(JSON.stringify(o) + '\n');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function play(file, gap) {
  const lines = fs.readFileSync(path.join(dir, file), 'utf8')
    .split('\n').filter(Boolean);
  for (const l of lines) {
    out(JSON.parse(l));
    if (gap > 0) await sleep(gap);
  }
}

// REPLAY_DIE_AFTER_ABORT=1 makes the fake crash (exit 1) right after the
// abort burst, mimicking a real pi that dies on an abort (e.g. an
// extension throwing "stale ctx" on the settled turn and exiting 1).
// Once REPLAY_STATE names a file, that file is written before dying; any
// later process (a :PiOpen restart) sees it and serves quick turns2 turns
// instead of the long turn1.
const dieAfterAbort = process.env.REPLAY_DIE_AFTER_ABORT === '1';
const stateFile = process.env.REPLAY_STATE || '';

process.stdin.on('data', (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i);
    buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    let c;
    try { c = JSON.parse(line); } catch { continue; }
    if (c.type === 'prompt') {
      prompts += 1;
      // replay the turn for the current prompt
      let file = prompts === 1 ? 'turn1.jsonl' : 'turn2.jsonl';
      if (stateFile && fs.existsSync(stateFile)) file = 'turn2.jsonl';
      play(file, 60).catch(() => {});
    } else if (c.type === 'abort') {
      // the real pi emits the whole abort burst at once
      play('abort.jsonl', 0).catch(() => {});
      if (dieAfterAbort) {
        setTimeout(() => {
          if (stateFile) fs.writeFileSync(stateFile, 'died\n');
          process.exit(1);
        }, 300);
      }
    }
  }
});
