#!/usr/bin/env bash
set -euo pipefail

if [[ -f api/coach/config.js ]]; then
  echo 'AI Coach is already present; nothing to port.'
  exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git remote remove alex 2>/dev/null || true
git remote add alex https://github.com/alexpcosta/opengym.git
git fetch alex main

set +e
git cherry-pick -m 1 9a539b94282c9272d1e493debd85c3730077e15d
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  echo 'Resolving known conflicts against current upstream...'

  # Preserve current upstream narrative and test skeleton.
  git checkout --ours CHANGELOG.md README.md .github/workflows/test.yml

  # .env is comments/config only, so union is safe and keeps both newer upstream knobs and
  # Coach's optional kill-switch documentation.
  d="$(mktemp -d)"
  git show :2:.env.example > "$d/ours"
  git show :1:.env.example > "$d/base"
  git show :3:.env.example > "$d/theirs"
  git merge-file --union "$d/ours" "$d/base" "$d/theirs" || true
  cp "$d/ours" .env.example
  rm -rf "$d"

  # Locale packs are JavaScript objects. Merge them semantically instead of line-unioning the
  # closing brace: keep today's upstream pack verbatim and append only keys that the Coach PR
  # introduced relative to its base. This preserves all newer translations and valid syntax.
  for f in frontend/src/locales/{de,es,fr,hi,it,ko,pl,pt,ru,tr,zh}.js; do
    d="$(mktemp -d)"
    git show ":2:$f" > "$d/ours.mjs"
    git show ":1:$f" > "$d/base.mjs"
    git show ":3:$f" > "$d/theirs.mjs"
    node --input-type=module - "$f" "$d/ours.mjs" "$d/base.mjs" "$d/theirs.mjs" <<'NODE'
import fs from 'node:fs'
import { pathToFileURL } from 'node:url'
const [target, oursPath, basePath, theirsPath] = process.argv.slice(2)
const load = async p => (await import(pathToFileURL(p).href + `?v=${Date.now()}-${Math.random()}`)).default
const [ours, base, theirs] = await Promise.all([load(oursPath), load(basePath), load(theirsPath)])
const added = Object.keys(theirs).filter(k => !(k in base) && !(k in ours))
let src = fs.readFileSync(oursPath, 'utf8')
const close = src.lastIndexOf('}')
if (close < 0) throw new Error(`no locale object close in ${target}`)
let head = src.slice(0, close).trimEnd()
if (!head.endsWith('{') && !head.endsWith(',')) head += ','
for (const key of added) head += `\n  ${JSON.stringify(key)}: ${JSON.stringify(theirs[key])},`
fs.writeFileSync(target, `${head}\n}\n`)
console.log(`${target}: added ${added.length} Coach translation keys`)
NODE
    rm -rf "$d"
  done

  # Keep upstream's newer OCI metadata and healthcheck, add the Coach runtime only.
  git show :2:api/Dockerfile > /tmp/api.Dockerfile.ours
  python3 - <<'PY'
from pathlib import Path
s = Path('/tmp/api.Dockerfile.ours').read_text()
marker = 'WORKDIR /app\nCOPY package.json package-lock.json* ./\n'
coach = '''WORKDIR /app

# ── AI Coach runtimes ─────────────────────────────────────────────────────────
# Pinned provider runtimes live in the API image; host Codex credentials are not mounted.
RUN apk add --no-cache bubblewrap libgcc libstdc++
RUN addgroup -S coach && adduser -S -G coach -H -s /sbin/nologin coach

COPY package.json package-lock.json* ./
'''
if marker not in s:
    raise SystemExit('Dockerfile WORKDIR/package marker moved')
s = s.replace(marker, coach, 1)
old = 'RUN npm install --omit=dev && npm cache clean --force\n'
new = '''RUN npm ci --omit=dev --include=optional \\
 && npm cache clean --force \\
 && node -e "import('@anthropic-ai/claude-agent-sdk').then(() => console.log('Claude Agent SDK ready'))" \\
 && ./node_modules/.bin/codex --version
'''
if old not in s:
    raise SystemExit('Dockerfile npm install marker moved')
s = s.replace(old, new, 1)
old = 'COPY server.js ./\n\nENV NODE_ENV=production\n'
new = 'COPY server.js ./\nCOPY coach/ ./coach/\n\nENV NODE_ENV=production\n'
if old not in s:
    raise SystemExit('Dockerfile server copy marker moved')
s = s.replace(old, new, 1)
Path('api/Dockerfile').write_text(s)
PY

  # server.js: only /api/config overlaps current upstream; keep allow_guest + Coach capability.
  python3 - <<'PY'
from pathlib import Path
import re
p = Path('api/server.js')
s = p.read_text()
pat = re.compile(r'''<<<<<<< HEAD\n\s*// Public config.*?\n\s*'GET /api/config':.*?\n=======\n.*?>>>>>>> 9a539b9 \(Merge pull request #1 from alexpcosta/ai-enablement\)\n''', re.S)
repl = '''  // Public config needed before sign-in. Preserve upstream guest mode and expose Coach only
  // when the instance has enabled it and connected a provider.
  'GET /api/config': async (req, res) => {
    const coach = coachConfig.publicConfig();
    json(res, 200, { invite_only: INVITE_ONLY, allow_guest: ALLOW_GUEST, ...(coach ? { coach } : {}) });
  },
'''
s2, n = pat.subn(repl, s, count=1)
if n != 1:
    raise SystemExit(f'expected one server config conflict, found {n}')
p.write_text(s2)
PY

  # sheets.jsx: upstream added Row while Coach added TextArea.
  python3 - <<'PY'
from pathlib import Path
import re
p = Path('frontend/src/sheets.jsx')
s = p.read_text()
pat = re.compile(r'''<<<<<<< HEAD\nimport \{ Button, Slider, Switch, Segmented, SelectRow, Row \} from './components/ui\.jsx'\n=======\n\s*import \{ Button, Slider, Switch, Segmented, SelectRow, TextArea \} from './components/ui\.jsx'\n>>>>>>> 9a539b9 \(Merge pull request #1 from alexpcosta/ai-enablement\)\n''')
repl = "import { Button, Slider, Switch, Segmented, SelectRow, Row, TextArea } from './components/ui.jsx'\n"
s2, n = pat.subn(repl, s, count=1)
if n != 1:
    raise SystemExit(f'expected one sheets import conflict, found {n}')
p.write_text(s2)
PY

  # Current loadConfig() already caches /api/config. Keep its guest handling; Coach consumes that same config.
  python3 - <<'PY'
from pathlib import Path
import re
p = Path('frontend/src/store/useStore.js')
s = p.read_text()
pat = re.compile(r'''<<<<<<< HEAD\n(\s*// Guests never authenticate,.*?if \(!guestAllowed\(cfg\)\) get\(\)\.setGuest\(false\)\n)=======\n.*?>>>>>>> 9a539b9 \(Merge pull request #1 from alexpcosta/ai-enablement\)\n''', re.S)
m = pat.search(s)
if not m:
    raise SystemExit('expected one store boot conflict')
s = s[:m.start()] + m.group(1) + s[m.end():]
p.write_text(s)
PY

  git add .env.example .github/workflows/test.yml CHANGELOG.md README.md api/Dockerfile api/server.js \
    frontend/src/locales/*.js frontend/src/sheets.jsx frontend/src/store/useStore.js

  unresolved="$(git diff --name-only --diff-filter=U)"
  if [[ -n "$unresolved" ]]; then
    echo 'Unresolved conflicts remain:'
    echo "$unresolved"
    exit 1
  fi
  GIT_EDITOR=true git cherry-pick --continue
fi

echo 'Running compatibility tests...'
npm ci --prefix api
npm test --prefix api
npm ci --prefix frontend
npm test --prefix frontend
npm run build --prefix frontend
node frontend/scripts/check-locales.mjs
npm ci --prefix mcp
npm test --prefix mcp
docker build -t opengym-api-coach-test ./api

git push origin HEAD:feature/ai-coach-codex
