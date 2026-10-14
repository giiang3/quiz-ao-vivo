// Configuração do backend (Supabase). A chave publicável é pública por design:
// as tabelas ficam fechadas e tudo passa por funções que exigem PIN/chaves.
window.QUIZ_CONFIG = window.QUIZ_CONFIG || {
  url: 'https://erwtihhmkszwkesjiooy.supabase.co',
  key: 'sb_publishable_9l7_lBcpFlBsyqhO_A6tqg__MBqfsQz'
};

const Api = {
  async rpc(fn, args, { timeout = 8000 } = {}) {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), timeout);
    let res;
    try {
      res = await fetch(`${QUIZ_CONFIG.url}/rest/v1/rpc/${fn}`, {
        method: 'POST',
        headers: {
          'apikey': QUIZ_CONFIG.key,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(args || {}),
        signal: ctrl.signal,
        cache: 'no-store'
      });
    } catch (e) {
      const err = new Error('Sem conexão. Tentando de novo…');
      err.network = true;
      throw err;
    } finally {
      clearTimeout(t);
    }
    const text = await res.text();
    let body = null;
    try { body = text ? JSON.parse(text) : null; } catch (_) { body = text; }
    if (!res.ok) {
      const err = new Error((body && body.message) || `Erro ${res.status}`);
      err.status = res.status;
      throw err;
    }
    return body;
  }
};

// Relógio do servidor: guardamos a diferença entre o relógio do servidor e o
// do aparelho, usando a medição com menor ida-e-volta, pra que a contagem
// regressiva apareça ao mesmo tempo em todas as telas.
const Clock = {
  offset: 0,
  bestRtt: Infinity,
  samples: 0,
  async timed(fn, args) {
    const t0 = Date.now();
    const out = await Api.rpc(fn, args);
    const t1 = Date.now();
    if (out && typeof out.now === 'number') {
      const rtt = t1 - t0;
      const est = out.now - (t0 + t1) / 2;
      this.samples++;
      // Aceita uma medição melhor, ou deixa a referência "envelhecer" devagar
      if (rtt <= this.bestRtt || this.samples < 3) {
        this.bestRtt = rtt;
        this.offset = est;
      } else {
        this.bestRtt += 5;
      }
    }
    return out;
  },
  now() { return Date.now() + this.offset; }
};

const Store = {
  get(k, fallback = null) {
    try { const v = localStorage.getItem(k); return v ? JSON.parse(v) : fallback; } catch (_) { return fallback; }
  },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (_) {} },
  del(k) { try { localStorage.removeItem(k); } catch (_) {} }
};

function el(tag, attrs = {}, ...children) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') n.className = v;
    else if (k === 'text') n.textContent = v;
    else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
    else if (k === 'style') n.setAttribute('style', v);
    else n.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat()) {
    if (c == null || c === false) continue;
    n.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return n;
}

const LETTERS = ['A', 'B', 'C', 'D'];
const fmt = (n) => (n || 0).toLocaleString('pt-BR');
