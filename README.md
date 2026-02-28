# wu-cli

**One binary. One port. All your micro-apps.**

Native Zig dev server and CLI toolkit for wu-framework microfrontend applications. Replaces N Vite dev servers with a single process -- one binary that discovers, compiles, and serves every micro-app through a unified HTTP server.

---

## Features

- Native HTTP dev server with SIMD-accelerated request parsing (16 bytes/cycle)
- Three-tier compilation: Native Zig JSX (0-2ms) -> Compiler Daemon (10-50ms) -> Node fallback (200-400ms)
- Two-level cache: in-memory (256 entries, mutex-protected) + persistent disk (`.wu-cache/`), 73-138x speedup on warm restart
- NPM module resolution in pure Zig (package.json `exports`, `module`, `main` fields with conditions)
- TypeScript stripping and bare-specifier import rewriting (`react` -> `/@modules/react`)
- CSS-as-module imports (`import './style.css'` injects into DOM at runtime)
- WebSocket (RFC 6455) + SSE-based HMR with 300ms file-watcher polling
- HTTP keep-alive for connection reuse across requests
- Interactive project scaffolding (`wu create`) and standalone dependency installer (`wu install`)
- Auto-discovery of micro-apps from directory structure (no config required)
- Framework support: React, Preact, Vue, Svelte, Solid, Lit, Angular, Alpine.js, Stencil, HTMX, Stimulus, Vanilla JS

## Install

```bash
npm install -g @wu-framework/cli
```

Then use it anywhere:

```bash
wu create my-project
cd my-project
wu dev
```

### Build from source

If you prefer to build from source (requires [Zig 0.15.2+](https://ziglang.org/download/)):

```bash
git clone https://github.com/LuisPadre25/wu-cli.git
cd wu-cli
zig build
./zig-out/bin/wu create my-project
```

## Commands

| Command | Description |
|---------|-------------|
| `wu dev` | Start native dev server (default) or Vite processes (`--vite`) |
| `wu build` | Build all micro-apps in parallel |
| `wu create` | Interactive project scaffolding (name, frameworks, install) |
| `wu add <framework> <name>` | Add a new micro-app to an existing project |
| `wu install` | Install project dependencies |
| `wu info` | Show project configuration and status |
| `wu serve` | Production server (coming soon) |

## Configuration

wu-cli reads a `wu.config.json` file at the project root. Example:

```json
{
  "shell": {
    "dir": "shell",
    "port": 4321,
    "framework": "astro"
  },
  "apps": [
    {
      "name": "dashboard",
      "dir": "mf-hero",
      "framework": "svelte",
      "port": 5002
    },
    {
      "name": "orders",
      "dir": "mf-eventlab",
      "framework": "react",
      "port": 5005
    }
  ]
}
```

Alternatively, wu-cli auto-discovers micro-apps by scanning subdirectories for the presence of both `vite.config.js` and `package.json`. No configuration file is required for basic usage.

## Architecture

```
src/
  commands/          CLI command handlers (dev, build, create, add, info, serve)
  runtime/           Dev server core
  config/            Configuration loading and validation
```

### Runtime modules

| Module | Purpose |
|--------|---------|
| **dev_server.zig** | Thread-per-connection HTTP server with keep-alive and static file serving |
| **http_parser.zig** | SIMD HTTP/1.1 request parser (16 bytes/cycle vectorized header scanning) |
| **resolve.zig** | NPM module resolution in pure Zig (zero Node.js dependency) |
| **transform.zig** | TypeScript erasure + bare-specifier import rewriting (line-preserving) |
| **jsx_transform.zig** | Native JSX to createElement transformation (React/Preact, ~0-2ms) |
| **compile.zig** | Three-tier framework compilation with persistent daemon process |
| **cache.zig** | Two-level mtime-based cache (in-memory 256 entries + disk `.wu-cache/`) |
| **ws_protocol.zig** | WebSocket RFC 6455 implementation (frame parsing, masking, handshake) |
| **mime.zig** | MIME type detection by file extension |

## Compilation Pipeline

```
.jsx/.tsx (React/Preact) ----> Native Zig JSX ----> JS  (~0-2ms)
.jsx/.tsx (Solid)        ----> Compiler Daemon ----> JS  (~10-50ms)
.svelte                  ----> Compiler Daemon ----> JS  (~10-50ms)
.vue                     ----> Compiler Daemon ----> JS  (~10-50ms)
.ts   (Angular)          ----> esbuild bundle  ----> JS  (~10-50ms)
.ts                      ----> TS Strip        ----> JS  (~0-1ms)
.js   (Alpine/HTMX/etc)  ----> passthrough     ----> JS  (~0ms)
```

The three tiers are tried in order. Native Zig handles React and Preact JSX with zero external processes. The Compiler Daemon keeps a long-running Node.js process for frameworks that require their own compilers (Svelte, Vue, Solid). If the daemon is unavailable, a one-shot `node -e` fallback is used.

Cache hits bypass all tiers entirely: the mtime of the source file is compared against the cached entry, and the cached output is served directly (~3ms).

## Supported Frameworks

| Framework | Extensions | Compile Tier | Native JSX |
|-----------|-----------|-------------|------------|
| React | .jsx, .tsx | Native Zig | Yes |
| Preact | .jsx, .tsx | Native Zig | Yes |
| Vue | .vue | Daemon / Node | -- |
| Svelte | .svelte | Daemon / Node | -- |
| Solid.js | .jsx, .tsx | Daemon / Node | -- |
| Angular | .ts | esbuild bundle | -- |
| Lit | .ts, .js | TS strip only | -- |
| Alpine.js | .js | Passthrough | -- |
| Stencil | .js | Passthrough | -- |
| HTMX | .js | Passthrough | -- |
| Stimulus | .js | Passthrough | -- |
| Vanilla | .js, .ts | TS strip only | -- |

## Requirements

- **Node.js 16+** -- for installing via npm (`npm install -g @wu-framework/cli`)
- **Node.js 18+** -- needed at runtime for Svelte, Vue, and Solid compilation (React/Preact use native Zig JSX)
- **Zig 0.15.2+** -- only needed if building from source

## Project Stats

- 22 Zig source files, ~2800 lines of runtime code
- ~250-460KB release binary per platform (Windows, Linux, macOS x64/arm64), zero external Zig dependencies
- Single-process architecture replaces 12+ simultaneous Vite dev servers
- Part of the wu-framework microfrontend platform

## License

MIT

## Author

Luis Garcia -- Creator of wu-framework

---

See [CONTRIBUTING.md](CONTRIBUTING.md) for development workflow and guidelines.
