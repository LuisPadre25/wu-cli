// WU Compiler Daemon — Persistent Node.js process for fast compilation
//
// Protocol (tab-separated, length-prefixed):
//   Request:  COMPILE\t{type}\t{filename}\t{loader}\t{jsxSource}\t{sourceLen}\n{sourceBytes}
//   Response: OK\t{codeLen}\n{codeBytes}   or   ERR\t{message}\n
//
// Stays alive for entire wu dev session. Eliminates Node startup per file.
// Cold compile: ~10-50ms (vs 200-400ms with node -e per file)

const fs = require('fs');

let buf = Buffer.alloc(0);
let pending = null;

process.stdin.resume();
process.stdin.on('data', chunk => {
  buf = Buffer.concat([buf, chunk]);
  drain();
});

function drain() {
  while (true) {
    if (!pending) {
      const nl = buf.indexOf(10);
      if (nl === -1) return;
      const parts = buf.slice(0, nl).toString().split('\t');
      buf = buf.slice(nl + 1);
      if (parts[0] !== 'COMPILE' || parts.length < 6) continue;
      pending = { t: parts[1], f: parts[2], l: parts[3], i: parts[4], n: parseInt(parts[5], 10) };
    }
    if (buf.length < pending.n) return;
    const src = buf.slice(0, pending.n).toString();
    buf = buf.slice(pending.n);
    const p = pending;
    pending = null;
    compile(p.t, p.f, p.l, p.i, src);
  }
}

function compile(type, filename, loader, jsxSrc, source) {
  try {
    let code;
    if (type === 'svelte') {
      code = require('svelte/compiler').compile(source, {
        generate: 'client', filename: filename
      }).js.code;
    } else if (type === 'vue') {
      const C = require('@vue/compiler-sfc');
      const { descriptor: d } = C.parse(source, { filename: filename });
      let sc = '', tp = '', b = {};
      if (d.scriptSetup || d.script) {
        const r = C.compileScript(d, { id: 'wu' });
        sc = r.content.replace(/export\s+default\s+/, 'const __sfc__=');
        b = r.bindings || {};
      }
      if (d.template) {
        tp = C.compileTemplate({
          source: d.template.content, filename: filename, id: 'wu',
          compilerOptions: { bindingMetadata: b }
        }).code;
      }
      code = sc + '\n' + tp + '\n';
      code += sc ? '__sfc__.render=render;\nexport default __sfc__;' : 'export default{render};';
    } else if (type === 'jsx' || type === 'tsx') {
      const o = { loader: loader || type, jsx: 'automatic', format: 'esm' };
      if (jsxSrc) o.jsxImportSource = jsxSrc;
      code = require('esbuild').transformSync(source, o).code;
    } else if (type === 'solid') {
      code = require('@babel/core').transformSync(source, {
        presets: ['babel-preset-solid'], filename: 'x.' + (loader || 'jsx')
      }).code;
    } else {
      throw new Error('Unknown type: ' + type);
    }
    const cb = Buffer.from(code);
    fs.writeSync(1, 'OK\t' + cb.length + '\n');
    fs.writeSync(1, cb);
  } catch (e) {
    fs.writeSync(1, 'ERR\t' + (e.message || 'fail').replace(/[\r\n]/g, ' ') + '\n');
  }
}
