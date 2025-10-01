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

app.get('/health', (req, res) => res.json({ status: 'ok' }));

const port = process.env.PORT || 3000;
app.listen(port, () => {
  console.log(`Node proxy listening on :${port}`);
});
