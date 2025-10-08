#!/usr/bin/env node
// GPU-enabled local dev launcher: Uses CUDA if available
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, readdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';

function sleep(ms){ return new Promise(r=>setTimeout(r,ms)); }

const root = join(process.cwd(), '..');
const pyDir = join(root, 'py');
const venv = join(pyDir, '.venv-gpu');  // Separate GPU venv
const isWin = process.platform === 'win32';

// Candidate base interpreters (ordered). On Windows 'py -3' is common.
const PY_CANDIDATES = isWin
  ? [ ['python', []], ['py', ['-3']], ['py', []], ['python3', []] ]
  : [ ['python3', []], ['python', []] ];

let basePythonCmd = null;
let usingSystemPython = false;

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
      const version = res.stdout.trim() || res.stderr.trim();
      console.log(`[dev-gpu] Using interpreter: ${cmd} ${args.join(' ')} (${version})`);
      basePythonCmd = { cmd, args };
      return true;
    }
  }
  console.error('[dev-gpu] Could not find Python interpreter');
  return false;
}

async function ensureVenv() {
  if (!detectBasePython()) return false;
  if (existsSync(pythonExe())) {
    console.log('[dev-gpu] GPU venv already exists');
    return true;
  }

  console.log('[dev-gpu] Creating GPU venv...');
  const { cmd, args } = basePythonCmd;
  const proc = run(cmd, [...args, '-m', 'venv', '.venv-gpu'], { cwd: pyDir });
  const code = await new Promise(res=> proc.on('close', res));
  
  if (code !== 0) {
    console.error(`[dev-gpu] venv creation failed with code ${code}`);
    return false;
  }

  // Wait for venv to be ready
  for(let i=0; i<60; i++){
    if (existsSync(pythonExe())) {
      console.log('[dev-gpu] GPU venv ready!');
      return true;
    }
    await sleep(500);
  }
  
  console.error('[dev-gpu] venv not ready after 30s');
  return false;
}

function checkCuda() {
  // Try to detect NVIDIA GPU
  if (isWin) {
    const res = spawnSync('nvidia-smi', [], { encoding: 'utf8' });
    if (res.status === 0) {
      console.log('[dev-gpu] ✅ NVIDIA GPU detected');
      console.log('[dev-gpu] nvidia-smi output:');
      console.log(res.stdout.split('\n').slice(0, 10).join('\n'));
      return true;
    }
  }
  console.warn('[dev-gpu] ⚠️  nvidia-smi not found - GPU may not be available');
  return false;
}

async function main() {
  console.log('='.repeat(60));
  console.log('GPU-Enabled Local Development');
  console.log('='.repeat(60));
  
  // Check for GPU
  const hasGpu = checkCuda();
  
  const ok = await ensureVenv();
  if(!ok){
    console.log('[dev-gpu] Aborting due to venv creation failure.');
    process.exit(1);
  }

  // Use GPU requirements file
  const reqFile = 'requirements-sam-gpu.txt';
  const pyCmd = pythonExe();
  
  console.log('[dev-gpu] Installing GPU dependencies from', reqFile);
  console.log('[dev-gpu] This may take 5-10 minutes on first run...');
  
  const pip = run(pyCmd, ['-m', 'pip', 'install', '--upgrade', 'pip'], { cwd: pyDir });
  await new Promise(res => pip.on('close', res));
  
  const pipInstall = run(pyCmd, ['-m', 'pip', 'install', '-r', reqFile], { cwd: pyDir });
  await new Promise(res => pipInstall.on('close', async (code) => {
    if (code !== 0) {
      console.error('[dev-gpu] pip install failed');
      process.exit(1);
    }
    
    // Verify PyTorch CUDA
    console.log('[dev-gpu] Verifying PyTorch CUDA installation...');
    const verify = spawnSync(pyCmd, ['-c', 'import torch; print(f"PyTorch: {torch.__version__}"); print(f"CUDA available: {torch.cuda.is_available()}"); print(f"CUDA device: {torch.cuda.get_device_name(0) if torch.cuda.is_available() else \'N/A\'}")'], {
      cwd: pyDir,
      encoding: 'utf8'
    });
    
    if (verify.status === 0) {
      console.log('[dev-gpu] ✅ PyTorch verification:');
      console.log(verify.stdout);
    } else {
      console.warn('[dev-gpu] ⚠️  PyTorch verification failed:');
      console.warn(verify.stderr);
    }
    
    console.log('[dev-gpu] Starting Flask SAM backend with GPU...');
    
    // Set environment variables for GPU usage
    const env = {
      ...process.env,
      CUDA_VISIBLE_DEVICES: '0',  // Use first GPU
      SAM_DEVICE: 'cuda',          // Force CUDA device
      TORCH_CUDA_ARCH_LIST: '8.9', // RTX 4000 Ada architecture
    };
    
    run(pyCmd, ['app.py'], { cwd: pyDir, env });
    
    // Wait for Flask to be ready
    console.log('[dev-gpu] Waiting for Flask backend to be ready...');
    const flaskReady = await waitForBackend('http://localhost:5001/health', 60000);
    if (!flaskReady) {
      console.warn('[dev-gpu] Flask did not respond within 60s. Starting Node proxy anyway...');
    } else {
      console.log('[dev-gpu] ✅ Flask backend ready!');
    }
    
    console.log('[dev-gpu] Starting Node proxy...');
    run('node', ['server.js']);
    
    console.log('='.repeat(60));
    console.log('🚀 Development servers running:');
    console.log('   Flask (GPU): http://localhost:5001');
    console.log('   Node Proxy:  http://localhost:3000');
    console.log('='.repeat(60));
    
    res();
  }));
}

async function waitForBackend(url, timeoutMs) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const { default: fetch } = await import('node-fetch');
      const resp = await fetch(url, { timeout: 2000 });
      if (resp.ok) return true;
    } catch (e) {
      // Flask not ready yet
    }
    await sleep(1000);
  }
  return false;
}

main();
