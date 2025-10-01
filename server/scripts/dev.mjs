#!/usr/bin/env node
// Cross-platform dev launcher: start Python SAM backend then Node proxy.
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

const root = join(process.cwd(), '..');
const pyDir = join(root, 'py');
const venv = join(pyDir, '.venv');
const isWin = process.platform === 'win32';

function run(cmd, args, opts = {}) {
  const p = spawn(cmd, args, { stdio: 'inherit', ...opts });
  return p;
}

function pythonExe() {
  if (isWin) return join(venv, 'Scripts', 'python.exe');
  return join(venv, 'bin', 'python');
}

async function ensureVenv() {
  if (!existsSync(venv)) {
    console.log('[dev] Creating venv...');
    run('python', ['-m', 'venv', '.venv'], { cwd: pyDir });
  }
}

async function main() {
  await ensureVenv();
  // Install requirements-sam.txt (falls back to requirements.txt if file missing)
  const reqFile = existsSync(join(pyDir, 'requirements-sam.txt')) ? 'requirements-sam.txt' : 'requirements.txt';
  console.log('[dev] Installing Python deps from', reqFile);
  run(pythonExe(), ['-m', 'pip', 'install', '-q', '-r', reqFile], { cwd: pyDir })
    .on('close', (code) => {
      if (code !== 0) {
        console.error('[dev] pip install failed');
        return;
      }
      console.log('[dev] Starting Flask SAM backend...');
      run(pythonExe(), ['app.py'], { cwd: pyDir });
    });

  console.log('[dev] Starting Node proxy...');
  run('node', ['server.js']);
}

main();
