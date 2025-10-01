#!/usr/bin/env node
// Cross-platform dev launcher: start Python SAM backend then Node proxy.
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, readdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';

function sleep(ms){ return new Promise(r=>setTimeout(r,ms)); }

const root = join(process.cwd(), '..');
const pyDir = join(root, 'py');
const venv = join(pyDir, '.venv');
const isWin = process.platform === 'win32';

// Candidate base interpreters (ordered). On Windows 'py -3' is common.
const PY_CANDIDATES = isWin
  ? [ ['python', []], ['py', ['-3']], ['py', []], ['python3', []] ]
  : [ ['python3', []], ['python', []] ];

let basePythonCmd = null; // {cmd, args}
let usingSystemPython = false; // fallback flag

function run(cmd, args, opts = {}) {
  const p = spawn(cmd, args, { stdio: 'inherit', ...opts });
  return p;
}

function pythonExe() {
  return isWin ? join(venv, 'Scripts', 'python.exe') : join(venv, 'bin', 'python');
}

function detectBasePython() {
  for (const [cmd, args] of PY_CANDIDATES) {
    const res = spawnSync(cmd, [...args, '--version'], { encoding: 'utf8' });
    if (res.status === 0) {
      console.log(`[dev] Using interpreter: ${cmd} ${args.join(' ')} (${res.stdout.trim() || res.stderr.trim()})`);
      basePythonCmd = { cmd, args };
      return true;
    }
  }
  console.error('[dev] Could not find a working Python interpreter (tried: ' + PY_CANDIDATES.map(c=>c[0] + (c[1].length? ' '+c[1].join(' '):'')).join(', ') + ')');
  console.error('[dev] Ensure Python 3.9+ is installed and on PATH. On Windows: https://www.python.org/downloads/');
  return false;
}

async function ensureVenv() {
  if (!detectBasePython()) return false;
  if (existsSync(pythonExe())) return true; // already created

  // Attempt creation (with one retry on failure/incomplete)
  for (let attempt=1; attempt<=2; attempt++) {
    if (!existsSync(venv)) {
      console.log(`[dev] Creating venv (attempt ${attempt})...`);
    } else {
      console.log(`[dev] Detected existing incomplete venv (attempt ${attempt})`);
    }
    const { cmd, args } = basePythonCmd;
    const proc = run(cmd, [...args, '-m', 'venv', '.venv'], { cwd: pyDir });
    const code = await new Promise(res=> proc.on('close', res));
    if (code !== 0) {
      console.error(`[dev] venv creation command exited with code ${code}`);
    }
    // Wait up to 60s (120 * 500ms) for python.exe to appear (slow disks / AV scanners)
    for(let i=0;i<120;i++){
      if (existsSync(pythonExe())) {
        console.log('[dev] venv ready.');
        return true;
      }
      await sleep(500);
    }
    // If still missing, collect diagnostics
    const diag = diagnostics();
    console.warn('[dev] venv python executable still missing after wait window. Diagnostics:', diag);
    if (attempt === 1) {
      console.log('[dev] Removing incomplete venv and retrying...');
      try { rmSync(venv, { recursive:true, force:true }); } catch(e){ console.warn('[dev] Failed to remove venv:', e.message); }
      continue;
    }
  }
  console.error('[dev] Python virtual environment not ready (missing python executable) after retries. Falling back to system interpreter.');
  usingSystemPython = true;
  return true; // allow fallback
}

function diagnostics(){
  const out = {};
  try { out.pyDirExists = existsSync(pyDir); } catch(_){}
  try { out.venvExists = existsSync(venv); } catch(_){}
  if(out.venvExists){
    try { out.venvEntries = readdirSync(venv); } catch(e){ out.venvEntries = 'ERR:'+e.message; }
    const scriptsDir = join(venv, isWin? 'Scripts':'bin');
    try { out.scriptsDirExists = existsSync(scriptsDir); } catch(_){}
    try { out.scriptsEntries = readdirSync(scriptsDir); } catch(e){ out.scriptsEntries = 'ERR:'+e.message; }
  }
  out.expectedPython = pythonExe();
  return out;
}

async function main() {
  const ok = await ensureVenv();
  if(!ok){
    console.log('[dev] Aborting dev script due to venv creation failure.');
    process.exit(1);
  }
  // Install requirements-sam.txt (falls back to requirements.txt if file missing)
  const reqFile = existsSync(join(pyDir, 'requirements-sam.txt')) ? 'requirements-sam.txt' : 'requirements.txt';
  if(usingSystemPython){
    console.warn('[dev] Using system Python (no venv). Dependencies will be installed globally or user-site. Consider fixing venv creation.');
  }
  const pyCmd = usingSystemPython ? (basePythonCmd.cmd) : pythonExe();
  const pyArgs = usingSystemPython ? (basePythonCmd.args||[]) : [];
  console.log('[dev] Installing Python deps from', reqFile);
  const pip = run(pyCmd, [...pyArgs, '-m', 'pip', 'install', '-q', '-r', reqFile], { cwd: pyDir })
    .on('close', async (code) => {
      if (code !== 0) {
        console.error('[dev] pip install failed');
        return;
      }
      console.log('[dev] Starting Flask SAM backend...');
      run(pyCmd, [...pyArgs, 'app.py'], { cwd: pyDir });
      
      // Wait for Flask to be ready before starting Node proxy
      console.log('[dev] Waiting for Flask backend to be ready...');
      const flaskReady = await waitForBackend('http://localhost:5001/health', 30000);
      if (!flaskReady) {
        console.warn('[dev] Flask did not respond within 30s. Starting Node proxy anyway...');
      } else {
        console.log('[dev] Flask backend ready!');
      }
      
      console.log('[dev] Starting Node proxy...');
      run('node', ['server.js']);
    });
}

async function waitForBackend(url, timeoutMs) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const { default: fetch } = await import('node-fetch');
      const resp = await fetch(url, { timeout: 2000 });
      if (resp.ok) return true;
    } catch (e) {
      // Connection refused or timeout - Flask not ready yet
    }
    await sleep(1000);
  }
  return false;
}

main();
