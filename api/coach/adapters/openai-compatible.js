/* Direct adapter for operator-controlled OpenAI-compatible local endpoints (llama.cpp, etc.).
 *
 * This is deliberately HTTP-only: no agent harness, shell, SDK or tool layer. The Coach already
 * builds the prompt and validates the returned JSON; this adapter only sends that prompt to the
 * configured chat-completions endpoint and returns the model text.
 *
 * The base URL is environment-only rather than editable from the admin UI. That keeps an admin
 * session from turning the server into an arbitrary SSRF client. For the Pi deployment point
 * COACH_OPENAI_BASE_URL at the existing Tailscale/local llama.cpp proxy.
 */

const configuredBase = () => String(process.env.COACH_OPENAI_BASE_URL || '').trim().replace(/\/+$/, '');
const configuredModel = () => String(process.env.COACH_OPENAI_MODEL || '').trim();

function timeoutSignal(ms) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  timer.unref?.();
  return { signal: controller.signal, cancel: () => clearTimeout(timer) };
}

async function request(url, init, timeoutMs) {
  const t = timeoutSignal(timeoutMs);
  try {
    return await fetch(url, { ...init, signal: t.signal });
  } finally {
    t.cancel();
  }
}

const adapter = {
  id: 'openai-compatible',

  async check() {
    const base = configuredBase();
    if (!base) return { ok: false, error: 'COACH_OPENAI_BASE_URL is not configured' };
    try {
      // /models is part of the OpenAI-compatible surface and is intentionally read-only.
      const res = await request(`${base}/models`, { headers: { Accept: 'application/json' } }, 90000);
      if (!res.ok) return { ok: false, error: `local model endpoint returned HTTP ${res.status}` };
      return { ok: true, version: 'OpenAI-compatible HTTP' };
    } catch (e) {
      return { ok: false, error: e?.name === 'AbortError' ? 'local model endpoint timed out' : String(e?.message || e).slice(0, 200) };
    }
  },

  async invoke({ prompt, model, timeoutMs }) {
    const base = configuredBase();
    const chosenModel = String(model || configuredModel()).trim();
    if (!base) return { code: 1, text: '', stderr: 'COACH_OPENAI_BASE_URL is not configured' };
    if (!chosenModel) return { code: 1, text: '', stderr: 'set a model in the Coach admin page or COACH_OPENAI_MODEL' };

    try {
      const res = await request(`${base}/chat/completions`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify({
          model: chosenModel,
          messages: [{ role: 'user', content: prompt }],
          temperature: 0.2,
          max_tokens: 1600,
          stream: false
        })
      }, timeoutMs);
      const raw = await res.text();
      if (!res.ok) return { code: res.status || 1, text: '', stderr: raw.slice(0, 1000) || `HTTP ${res.status}` };
      let body;
      try { body = JSON.parse(raw); }
      catch { return { code: 1, text: '', stderr: 'local model endpoint returned invalid JSON' }; }
      const text = body?.choices?.[0]?.message?.content;
      if (typeof text !== 'string') return { code: 1, text: '', stderr: 'local model response had no choices[0].message.content' };
      return { code: 0, text: text.trim(), stderr: '' };
    } catch (e) {
      if (e?.name === 'AbortError') return { code: -1, text: '', stderr: 'local model request timed out', timedOut: true };
      return { code: -1, text: '', stderr: String(e?.message || e).slice(0, 1000), spawnError: true };
    }
  }
};

export default adapter;
