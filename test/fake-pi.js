#!/usr/bin/env node
// Minimal fake of pi's --mode rpc, for exercising the vim plugin without a
// real model. Speaks just enough of the JSONL protocol to drive the plugin's
// event handlers. Protocol shapes follow docs/rpc.md: responses are
//   {"id": ..., "type": "response", "command": ..., "success": true}
// and events are flat JSON lines:
//   {"type": "<event_name>", ...payload}
//
// For each `prompt` it emits a canned reply plus (env-controlled) a thinking
// block and/or tool executions, so the test suite can exercise the handlers:
//   FAKE_PI_THINKING=1     emit thinking_delta frames before the reply
//   FAKE_PI_TOOL=bash      which tool to run: bash|read|edit|write|multi|none
//                          (default bash; 'multi' runs bash+read+edit)
//   FAKE_PI_EDIT_PATH=p    args.path for an edit/write tool (reload target)
//   FAKE_PI_TOOLFAIL=1     the tool ends with isError=true
//   FAKE_PI_TITLE=t        the notify title (default 'pi')
//   FAKE_PI_REPLY_PREFIX=  reply prefix (default 'Echo: ')
//
// It keeps running until stdin closes (the plugin :quit!s the job to tear it
// down).
'use strict';

// Record our launch argv (lets tests verify startup flags like --no-session).
// Appended, so a restarted fake (e.g. after :PiClear) leaves one line per launch.
if (process.env.FAKE_PI_ARGV_LOG) {
  try { require('fs').appendFileSync(process.env.FAKE_PI_ARGV_LOG, JSON.stringify(process.argv) + '\n'); } catch {}
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buf += chunk;
  let idx;
  while ((idx = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, idx).replace(/\r$/, '');
    buf = buf.slice(idx + 1);
    if (!line) continue;
    if (process.env.FAKE_PI_LOG) {
      try { require('fs').appendFileSync(process.env.FAKE_PI_LOG, line + '\n'); } catch {}
    }
    let req;
    try { req = JSON.parse(line); } catch { continue; }
    switch (req && req.type) {
      case 'prompt': {
        const m = (req.message || '').slice(0, 80);
        emit({ id: req.id, type: 'response', command: 'prompt', success: true });
        const delay = parseInt(process.env.FAKE_PI_DELAY_MS || '150', 10);
        const turn  = parseInt(process.env.FAKE_PI_TURN_MS  || '150', 10);
        const tool  = process.env.FAKE_PI_TOOL || 'bash';
        const think = process.env.FAKE_PI_THINKING === '1';
        const thinkText = process.env.FAKE_PI_THINKING_TEXT || 'Thinking: weighing the options';
        const title = process.env.FAKE_PI_TITLE || 'pi';
        const prefix= process.env.FAKE_PI_REPLY_PREFIX || 'Echo: ';
        const editPath = process.env.FAKE_PI_EDIT_PATH || 'ctx.txt';
        const toolFail  = process.env.FAKE_PI_TOOLFAIL === '1';

        setTimeout(() => {
          emit({ type: 'agent_start' });

          if (think) {
            emit({ type: 'message_start', message: { role: 'assistant' } });
            for (const c of thinkText) {
              emit({ type: 'message_update', assistantMessageEvent: { type: 'thinking_delta', delta: c } });
            }
            emit({ type: 'message_end', message: { role: 'assistant' } });
          }

          const reply = `${prefix}${m}`;
          emit({ type: 'message_start', message: { role: 'assistant' } });
          for (const c of reply) {
            emit({ type: 'message_update', assistantMessageEvent: { type: 'text_delta', delta: c } });
          }
          emit({ type: 'message_update', assistantMessageEvent: { type: 'text_end', content: reply } });
          emit({ type: 'message_end', message: { role: 'assistant' } });

          const tools = tool === 'multi' ? ['bash', 'read', 'edit'] : [tool];
          let i = 0;
          const runNext = () => {
            if (i >= tools.length) {
              finish();
              return;
            }
            const name = tools[i++];
            const args =
              name === 'bash' ? { command: 'echo fake' }
              : name === 'read' ? { path: editPath }
              : { path: editPath };
            emit({ type: 'tool_execution_start', toolName: name, args });
            setTimeout(() => {
              emit({ type: 'tool_execution_update', toolName: name, partialResult: name + ' output\n' });
              setTimeout(() => {
                emit({ type: 'tool_execution_end', toolName: name, isError: toolFail && name === tools[0] });
                runNext();
              }, turn);
            }, turn);
          };
          if (tools.length) runNext(); else finish();

          function finish() {
            const ntype = process.env.FAKE_PI_NOTIFY_TYPE || '';
            const base = { type: 'extension_ui_request', id: 'ui-1', method: 'notify', title, message: `fake reply to: ${m}` };
            emit(ntype && ntype !== 'info' ? Object.assign({}, base, { notifyType: ntype }) : base);
            if (process.env.FAKE_PI_NOTIFY_ALL) {
              emit({ type: 'extension_ui_request', id: 'ui-2', method: 'notify', title, message: 'info note', notifyType: 'info' });
              emit({ type: 'extension_ui_request', id: 'ui-3', method: 'notify', title, message: 'warn note', notifyType: 'warning' });
              emit({ type: 'extension_ui_request', id: 'ui-4', method: 'notify', title, message: 'error note', notifyType: 'error' });
            }
            emit({ type: 'agent_end', willRetry: false });
            emit({ type: 'agent_settled' });
          }
        }, delay);
        break;
      }
      case 'abort':
        emit({ id: req.id, type: 'response', command: 'abort', success: true });
        emit({ type: 'agent_end', willRetry: false });
        emit({ type: 'agent_settled' });
        break;
      case 'set_model':
      case 'clear':
      case 'new_session':
      default:
        if (req && req.id != null) {
          emit({ id: req.id, type: 'response', command: req.type, success: true });
        }
        break;
    }
  }
});
process.stdin.on('end', () => process.exit(0));

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}
