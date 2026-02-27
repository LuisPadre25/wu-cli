#!/usr/bin/env node

const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PLATFORM_MAP = {
  'win32-x64':   'wu-win32-x64.exe',
  'linux-x64':   'wu-linux-x64',
  'darwin-x64':  'wu-darwin-x64',
  'darwin-arm64': 'wu-darwin-arm64',
};

const platform = os.platform();
const arch = os.arch();
const key = `${platform}-${arch}`;
const binaryName = PLATFORM_MAP[key];

if (!binaryName) {
  console.error(`wu-cli: unsupported platform ${platform}-${arch}`);
  console.error(`Supported: ${Object.keys(PLATFORM_MAP).join(', ')}`);
  process.exit(1);
}

const binaryPath = path.join(__dirname, binaryName);

if (!fs.existsSync(binaryPath)) {
  console.error(`wu-cli: binary not found at ${binaryPath}`);
  console.error('This may mean the package was not built for your platform.');
  console.error('Try reinstalling: npm install -g wu-cli');
  process.exit(1);
}

const args = process.argv.slice(2);

let result = spawnSync(binaryPath, args, {
  stdio: 'inherit',
  env: process.env,
});

// Handle EACCES — try chmod +x and retry (Linux/macOS)
if (result.error && result.error.code === 'EACCES') {
  try {
    fs.chmodSync(binaryPath, 0o755);
    result = spawnSync(binaryPath, args, {
      stdio: 'inherit',
      env: process.env,
    });
  } catch (chmodErr) {
    console.error(`wu-cli: permission denied and could not chmod: ${chmodErr.message}`);
    process.exit(1);
  }
}

if (result.error) {
  console.error(`wu-cli: failed to execute binary: ${result.error.message}`);
  process.exit(1);
}

process.exit(result.status ?? 1);
