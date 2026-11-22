#!/usr/bin/env node
/** Minimal ACP client driving pi-acp (the real ACP server extension). */
'use strict';
const { spawn } = require('child_process');
const readline = require('readline');
const path = require('path');

const server = spawn(
  path.join(__dirname, 'node_modules', '.bin', 'pi-acp'),
  [], { stdio: ['pipe','pipe','pipe'], env: process.env }
);
const rl = readline.createInterface({ input: server.stdout, crlfDelay: Infinity });
let reqId = 0;
const pending = new Map();

server.stderr.on('data', d => process.stderr.write(`[stderr] ${d}`));
server.on('exit', c => console.error('[exit]', c));

function call(method, params, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const id = `c${++reqId}`;
    const t = setTimeout(() => { pending.delete(id); reject(new Error('timeout:'+method)); }, timeoutMs);
    pending.set(id, { resolve: (r)=>{clearTimeout(t);resolve(r);}, reject:(e)=>{clearTimeout(t);reject(e);} });
    server.stdin.write(JSON.stringify({ jsonrpc:'2.0', id, method, params }) + '\n');
  });
}

rl.on('line', (line) => {
  let rec; try { rec = JSON.parse(line); } catch { return; }
  if (rec.id && pending.has(rec.id)) {
    const p = pending.get(rec.id); pending.delete(rec.id);
    if (rec.error) p.reject(new Error(JSON.stringify(rec.error)));
    else p.resolve(rec.result);
  } else if (rec.method === 'push' || rec.method === 'session/update') {
    const u = (rec.params && rec.params.update) || (rec.params && rec.params.sessionUpdate);
    const kind = u && u.sessionUpdate;
    if (kind === 'agent_message_chunk') {
      const c = u.content && u.content.type==='text' ? u.content.text : '';
      process.stdout.write(c);
    } else if (kind === 'agent_message') {
      process.stdout.write('\n[agent_message]\n');
    } else if (kind === 'session_info') {
      // silent
    } else if (kind === 'usage_update') {
      process.stdout.write(`\n[usage] ${JSON.stringify(u.usage||u).slice(0,60)}\n`);
    } else {
      process.stdout.write(`\n[evt:${kind}]\n`);
    }
  } else if (rec.method === 'terminal') {
    process.stdout.write(`\n[terminal]\n`);
  } else {
    process.stdout.write(`\n[recv:${rec.method||''}] `+JSON.stringify(rec.params||rec.result||'').slice(0,80)+'\n');
  }
});

async function main() {
  try {
    const init = await call('initialize', { protocolVersion: 1 }, 15000);
    console.log('[init]', JSON.stringify(init));
  } catch (e) { console.log('[init ERR]', e.message); }

  try {
    const ns = await call('session/new', { cwd: process.cwd(), mcpServers: [] }, 20000);
    console.log('[newSession]', JSON.stringify(ns));
    global.__sid = ns.sessionId;
  } catch (e) { console.log('[newSession ERR]', e.message); }

  if (global.__sid) {
    try {
      await call('session/prompt', { sessionId: global.__sid, prompt: [{ type:'text', text:'Reply with exactly: ACP-PIAC OK' }] }, 20000);
      console.log('[prompt] streaming...\n');
      await new Promise(r => setTimeout(r, 30000));
    } catch (e) { console.log('[prompt ERR]', e.message); }
  }
  console.log('\n[done]');
  server.stdin.end();
  setTimeout(()=>process.exit(0), 800);
}
main().catch(e=>{console.error('[fatal]',e.message);process.exit(1);});
