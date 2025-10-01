import express from 'express';
import multer from 'multer';
import fetch from 'node-fetch';
import FormData from 'form-data';
import path from 'path';
import { fileURLToPath } from 'url';

const PY_SERVICE_URL = process.env.PY_SERVICE_URL || 'http://localhost:5001';

const app = express();
const upload = multer();

// Serve static UI
const __dirname = path.dirname(fileURLToPath(import.meta.url));
app.use(express.static(path.join(__dirname, 'public')));

app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// Removed classic segmentation/apply proxy endpoints

// ---------------- SAM proxy endpoints ----------------
app.post('/api/sam/init', upload.single('image'), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'image file required' });
  try {
    const form = new FormData();
    form.append('image', req.file.buffer, { filename: req.file.originalname || 'image.png' });
    const resp = await fetch(`${PY_SERVICE_URL}/sam/init`, { method: 'POST', body: form, headers: form.getHeaders() });
    const data = await resp.json();
    return res.status(resp.status).json(data);
  } catch (e) {
    console.error(e); return res.status(500).json({ error: 'proxy error' });
  }
});

app.post('/api/sam/segment', express.json(), async (req, res) => {
  try {
    const resp = await fetch(`${PY_SERVICE_URL}/sam/segment`, { method: 'POST', body: JSON.stringify(req.body), headers: { 'Content-Type': 'application/json' } });
    const data = await resp.json();
    return res.status(resp.status).json(data);
  } catch (e) { console.error(e); return res.status(500).json({ error: 'proxy error' }); }
});

app.post('/api/sam/save_component', express.json(), async (req, res) => {
  try {
    const resp = await fetch(`${PY_SERVICE_URL}/sam/save_component`, { method: 'POST', body: JSON.stringify(req.body), headers: { 'Content-Type': 'application/json' } });
    const data = await resp.json();
    return res.status(resp.status).json(data);
  } catch (e) { console.error(e); return res.status(500).json({ error: 'proxy error' }); }
});

app.get('/api/sam/components', async (req, res) => {
  try {
    const url = new URL(`${PY_SERVICE_URL}/sam/components`);
    if (req.query.image_id) url.searchParams.set('image_id', req.query.image_id);
    const resp = await fetch(url, { method: 'GET' });
    const data = await resp.json();
    return res.status(resp.status).json(data);
  } catch (e) { console.error(e); return res.status(500).json({ error: 'proxy error' }); }
});

app.post('/api/sam/apply', express.json(), async (req, res) => {
  try {
    const resp = await fetch(`${PY_SERVICE_URL}/sam/apply`, { method: 'POST', body: JSON.stringify(req.body), headers: { 'Content-Type': 'application/json' } });
    const data = await resp.json();
    return res.status(resp.status).json(data);
  } catch (e) { console.error(e); return res.status(500).json({ error: 'proxy error' }); }
});

// ---------- Batch processing (non-stream) ----------
app.post('/api/sam/batch_process', upload.array('images'), async (req, res) => {
  if (!req.files || !req.files.length) return res.status(400).json({ error: 'images required' });
  try {
    const form = new FormData();
    for (const f of req.files) {
      form.append('images', f.buffer, { filename: f.originalname || 'image.png' });
    }
    // Forward optional fields
    if (req.body.mode) form.append('mode', req.body.mode);
    if (req.body.export_mask) form.append('export_mask', req.body.export_mask);
    if (req.body.edits) form.append('edits', req.body.edits);
    const resp = await fetch(`${PY_SERVICE_URL}/sam/batch_process`, { method: 'POST', body: form, headers: form.getHeaders() });
    const data = await resp.json();
    return res.status(resp.status).json(data);
  } catch (e) { console.error(e); return res.status(500).json({ error: 'proxy error' }); }
});

// ---------- Batch processing (streaming SSE) ----------
app.post('/api/sam/batch_process_stream', upload.array('images'), async (req, res) => {
  if (!req.files || !req.files.length) return res.status(400).json({ error: 'images required' });
  try {
    const form = new FormData();
    for (const f of req.files) {
      form.append('images', f.buffer, { filename: f.originalname || 'image.png' });
    }
    if (req.body.mode) form.append('mode', req.body.mode);
    if (req.body.export_mask) form.append('export_mask', req.body.export_mask);
    if (req.body.edits) form.append('edits', req.body.edits);

    const pyResp = await fetch(`${PY_SERVICE_URL}/sam/batch_process_stream`, { method: 'POST', body: form, headers: form.getHeaders() });
    // Mirror status code unless streaming is successful (treat non-200 as error JSON)
    if (!pyResp.ok && pyResp.headers.get('content-type')?.includes('application/json')) {
      const errData = await pyResp.json();
      return res.status(pyResp.status).json(errData);
    }
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    // Pipe streaming body
    pyResp.body.on('data', chunk => {
      res.write(chunk);
    });
    pyResp.body.on('end', () => {
      res.end();
    });
    pyResp.body.on('error', (err) => {
      console.error('stream proxy error', err);
      try { res.write('data: {"error":"stream proxy error"}\n\n'); } catch(_) {}
      res.end();
    });
  } catch (e) { console.error(e); return res.status(500).json({ error: 'proxy error' }); }
});

// ---------- Dataset workflow proxies ----------
// Initialize dataset with multiple images
app.post('/api/sam/dataset/init', upload.array('images'), async (req, res) => {
  if (!req.files || !req.files.length) return res.status(400).json({ error: 'images required' });
  try {
    const form = new FormData();
    for (const f of req.files) {
      form.append('images', f.buffer, { filename: f.originalname || 'image.png' });
    }
    const resp = await fetch(`${PY_SERVICE_URL}/sam/dataset/init`, { method: 'POST', body: form, headers: form.getHeaders() });
    const data = await resp.json();
    return res.status(resp.status).json(data);
  } catch (e) { console.error(e); return res.status(500).json({ error: 'proxy error' }); }
});

// Save a template (JSON body)
app.post('/api/sam/dataset/template/save', express.json(), async (req, res) => {
  try {
    const resp = await fetch(`${PY_SERVICE_URL}/sam/dataset/template/save`, { method: 'POST', body: JSON.stringify(req.body), headers: { 'Content-Type': 'application/json' } });
    const data = await resp.json();
    return res.status(resp.status).json(data);
  } catch (e) { console.error(e); return res.status(500).json({ error: 'proxy error' }); }
});

// List templates
app.get('/api/sam/dataset/templates', async (req, res) => {
  try {
    const url = new URL(`${PY_SERVICE_URL}/sam/dataset/templates`);
    if (req.query.dataset_id) url.searchParams.set('dataset_id', req.query.dataset_id);
    const resp = await fetch(url, { method: 'GET' });
    const data = await resp.json();
    return res.status(resp.status).json(data);
  } catch (e) { console.error(e); return res.status(500).json({ error: 'proxy error' }); }
});

// Apply templates streaming
app.post('/api/sam/dataset/apply_stream', express.json(), async (req, res) => {
  try {
    const pyResp = await fetch(`${PY_SERVICE_URL}/sam/dataset/apply_stream`, { method: 'POST', body: JSON.stringify(req.body), headers: { 'Content-Type': 'application/json' } });
    if (!pyResp.ok && pyResp.headers.get('content-type')?.includes('application/json')) {
      const errData = await pyResp.json();
      return res.status(pyResp.status).json(errData);
    }
    res.setHeader('Content-Type', 'text/event-stream');
    res.setHeader('Cache-Control', 'no-cache');
    res.setHeader('Connection', 'keep-alive');
    pyResp.body.on('data', chunk => res.write(chunk));
    pyResp.body.on('end', () => res.end());
    pyResp.body.on('error', err => { console.error('dataset stream proxy error', err); try { res.write('data: {"error":"stream proxy error"}\n\n'); } catch(_) {} res.end(); });
  } catch (e) { console.error(e); return res.status(500).json({ error: 'proxy error' }); }
});

// Point preview (real-time SAM mask)
app.post('/api/sam/dataset/point_preview', express.json(), async (req, res) => {
  try {
    const resp = await fetch(`${PY_SERVICE_URL}/sam/dataset/point_preview`, { method: 'POST', body: JSON.stringify(req.body), headers: { 'Content-Type': 'application/json' } });
    const data = await resp.json();
    return res.status(resp.status).json(data);
  } catch (e) { console.error(e); return res.status(500).json({ error: 'proxy error' }); }
});

// Template preview (before generation)
app.post('/api/sam/dataset/template/preview', express.json(), async (req, res) => {
  try {
    const resp = await fetch(`${PY_SERVICE_URL}/sam/dataset/template/preview`, { method: 'POST', body: JSON.stringify(req.body), headers: { 'Content-Type': 'application/json' } });
    const data = await resp.json();
    return res.status(resp.status).json(data);
  } catch (e) { console.error(e); return res.status(500).json({ error: 'proxy error' }); }
});

app.get('/health', (req, res) => res.json({ status: 'ok' }));

// Only start listening if not running under test harness
if (process.env.NODE_ENV !== 'test') {
  const port = process.env.PORT || 3000;
  app.listen(port, () => {
    console.log(`Node proxy listening on :${port}`);
  });
}

export default app;
