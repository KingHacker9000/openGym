import test from 'node:test';
import assert from 'node:assert/strict';
import adapter from '../coach/adapters/openai-compatible.js';

const OLD_BASE = process.env.COACH_OPENAI_BASE_URL;
const OLD_MODEL = process.env.COACH_OPENAI_MODEL;
const OLD_FETCH = globalThis.fetch;

test.afterEach(() => {
  if (OLD_BASE === undefined) delete process.env.COACH_OPENAI_BASE_URL; else process.env.COACH_OPENAI_BASE_URL = OLD_BASE;
  if (OLD_MODEL === undefined) delete process.env.COACH_OPENAI_MODEL; else process.env.COACH_OPENAI_MODEL = OLD_MODEL;
  globalThis.fetch = OLD_FETCH;
});

test('local provider refuses to pretend it is configured without an endpoint', async () => {
  delete process.env.COACH_OPENAI_BASE_URL;
  const r = await adapter.check();
  assert.equal(r.ok, false);
  assert.match(r.error, /COACH_OPENAI_BASE_URL/);
});

test('check uses the read-only OpenAI-compatible models endpoint', async () => {
  process.env.COACH_OPENAI_BASE_URL = 'http://pi-model.test/v1/';
  let seen = null;
  globalThis.fetch = async (url, init) => {
    seen = { url: String(url), method: init?.method || 'GET' };
    return new Response('{"data":[]}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  const r = await adapter.check();
  assert.deepEqual(seen, { url: 'http://pi-model.test/v1/models', method: 'GET' });
  assert.equal(r.ok, true);
});

test('invoke sends one ordinary chat-completions request and returns only model text', async () => {
  process.env.COACH_OPENAI_BASE_URL = 'http://pi-model.test/v1';
  process.env.COACH_OPENAI_MODEL = 'qwen-local';
  let request = null;
  globalThis.fetch = async (url, init) => {
    request = { url: String(url), body: JSON.parse(init.body) };
    return new Response(JSON.stringify({ choices: [{ message: { content: '{"coach_contract":1,"ok":true}' } }] }), {
      status: 200, headers: { 'content-type': 'application/json' }
    });
  };
  const r = await adapter.invoke({ prompt: 'coach prompt', model: null, timeoutMs: 1000 });
  assert.equal(request.url, 'http://pi-model.test/v1/chat/completions');
  assert.equal(request.body.model, 'qwen-local');
  assert.deepEqual(request.body.messages, [{ role: 'user', content: 'coach prompt' }]);
  assert.equal(request.body.stream, false);
  assert.equal(r.code, 0);
  assert.equal(r.text, '{"coach_contract":1,"ok":true}');
});
