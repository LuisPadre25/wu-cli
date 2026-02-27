import _wuPkg from 'wu-framework';
const wu = _wuPkg.default || _wuPkg;
if (typeof window !== 'undefined') window.wu = wu;

// Entry points: loaded ONLY when user navigates to each section
const appEntries = {
  '21': '/mf-21/src/main.jsx',
  'fef': '/mf-fef/src/main.js',
  'k': '/mf-k/src/main.js',
  'j': '/mf-j/src/main.jsx',
  'i': '/mf-i/src/main.jsx',
  'i6': '/mf-i6/src/main.js',
  'oo': '/mf-oo/src/main.js',
};

// Navigation — lazy load AND mount on first visit
const mounted = new Set();

window.switchSection = async function switchSection(name) {
  document.querySelectorAll('.section').forEach(s => s.classList.remove('active'));
  document.querySelectorAll('nav button').forEach(b => b.classList.remove('active'));
  const el = document.getElementById('section-' + name);
  const btn = document.querySelector(`button[data-section="${name}"]`);
  if (el) el.classList.add('active');
  if (btn) btn.classList.add('active');

  // Lazy load + mount: first visit loads the app code, then mounts
  if (name !== 'welcome' && !mounted.has(name)) {
    mounted.add(name);
    const entry = appEntries[name];
    if (entry) await import(entry);
    const container = document.getElementById('wu-app-' + name);
    const tryMount = () => {
      const def = wu.definitions.get(name);
      if (def && container) { def.mount(container); return true; }
      return false;
    };
    if (!tryMount()) {
      const h = setInterval(() => { if (tryMount()) clearInterval(h); }, 50);
      setTimeout(() => clearInterval(h), 5000);
    }
  }
}

document.querySelectorAll('[data-section]').forEach(el => {
  el.addEventListener('click', () => switchSection(el.dataset.section));
});

console.log('%c[wu] Shell ready — apps load on demand', 'color: #a78bfa; font-weight: bold');
