import express from 'express';
import multer from 'multer';
import fetch from 'node-fetch';
import FormData from 'form-data';
import path from 'path';
import { fileURLToPath } from 'url';
import crypto from 'crypto';
import { S3Client } from '@aws-sdk/client-s3';
import { createPresignedPost } from '@aws-sdk/s3-presigned-post';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, PutCommand, GetCommand } from '@aws-sdk/lib-dynamodb';
import { SQSClient, SendMessageCommand } from '@aws-sdk/client-sqs';

const PY_SERVICE_URL = process.env.PY_SERVICE_URL || 'http://localhost:5001';
const REGION = process.env.AWS_REGION || 'us-east-1';
const DATASETS_BUCKET = process.env.DATASETS_BUCKET; // optional (only needed for presign)
const OUTPUTS_BUCKET  = process.env.OUTPUTS_BUCKET;  // reserved for future listing
const JOBS_TABLE      = process.env.JOBS_TABLE || 'sam_jobs';
const JOBS_QUEUE_URL  = process.env.JOBS_QUEUE_URL; // SQS queue URL
const API_KEY         = process.env.API_KEY; // simple shared secret
const PROXY_DEBUG     = process.env.PROXY_DEBUG === '1';

// AWS clients (lazy usable even if not fully configured)
const s3  = new S3Client({ region: REGION });
const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region: REGION }));
const sqs = new SQSClient({ region: REGION });

const app = express();
app.use(express.json({ limit: '1mb' }));
const upload = multer();

// Serve static UI
const __dirname = path.dirname(fileURLToPath(import.meta.url));
app.use(express.static(path.join(__dirname, 'public')));

app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// ------------------------------------------------------------------
// Simple API key auth middleware
// ------------------------------------------------------------------
function checkKey(req, res, next) {
  if (!API_KEY) return next(); // no key set, open access
  const k = req.headers['x-api-key'];
  if (k === API_KEY) return next();
  return res.status(401).json({ error: 'bad api key' });
}

// Small helper to log backend proxy details when debugging
function logProxy(name, info) {
  if (!PROXY_DEBUG) return;
  try { console.log(`[proxy:${name}]`, typeof info === 'string' ? info : JSON.stringify(info)); } catch(_) {}
}

// ------------------------------------------------------------------
// Cloud integration endpoints (Phase 1A/1B)
// ------------------------------------------------------------------
// Generate S3 presigned POST for client-side multi-file uploads.
app.post('/api/presign', checkKey, async (req, res) => {
  try {
    const { datasetId } = req.body || {};
    if (!datasetId) return res.status(400).json({ error: 'datasetId required' });
    if (!DATASETS_BUCKET) return res.status(500).json({ error: 'DATASETS_BUCKET not configured' });
    const keyPrefix = `datasets/${datasetId}/`;
    const post = await createPresignedPost(s3, {
      Bucket: DATASETS_BUCKET,
      Key: keyPrefix + '${filename}',
      Conditions: [
        ['starts-with', '$key', keyPrefix],
        ['content-length-range', 0, 40 * 1024 * 1024]
      ],
      Expires: 3600
    });
    res.json({ datasetId, post });
  } catch (e) {
    console.error('[presign] error', e);
    res.status(500).json({ error: 'presign failed' });
  }
});

// Create a job (persist -> enqueue)
app.post('/api/jobs', checkKey, async (req, res) => {
  try {
    const { datasetId, templates, edits, mode } = req.body || {};
    if (!datasetId) return res.status(400).json({ error: 'datasetId required' });
    if (!JOBS_QUEUE_URL) return res.status(500).json({ error: 'JOBS_QUEUE_URL not configured' });
    const job_id = crypto.randomUUID();
    const now = new Date().toISOString();
    const item = {
      job_id,
      status: 'queued',
      progress: 0,
      dataset_prefix: `datasets/${datasetId}/`,
      output_prefix: `outputs/${job_id}/`,
      created_at: now,
      updated_at: now,
      mode: mode || 'quality'
    };
    await ddb.send(new PutCommand({ TableName: JOBS_TABLE, Item: item }));
    const msgBody = { job_id, dataset_prefix: item.dataset_prefix, output_prefix: item.output_prefix, templates, edits, mode };
    await sqs.send(new SendMessageCommand({ QueueUrl: JOBS_QUEUE_URL, MessageBody: JSON.stringify(msgBody) }));
    res.json({ job_id, status: 'queued' });
  } catch (e) {
    console.error('[jobs] enqueue error', e);
    res.status(500).json({ error: 'enqueue failed' });
  }
});

// Poll job status
app.get('/api/jobs/:id', checkKey, async (req, res) => {
  try {
    const out = await ddb.send(new GetCommand({ TableName: JOBS_TABLE, Key: { job_id: req.params.id } }));
    if (!out.Item) return res.status(404).json({ error: 'not found' });
    res.json(out.Item);
  } catch (e) {
    console.error('[jobs] read error', e);
    res.status(500).json({ error: 'read failed' });
  }
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
    if (!resp.ok) logProxy('sam/init', { status: resp.status, data });
    return res.status(resp.status).json(data);
  } catch (e) {
    console.error('[proxy sam/init] error', e);
    return res.status(500).json({ error: 'proxy error', detail: String(e) });
  }
});

app.post('/api/sam/segment', express.json(), async (req, res) => {
  try {
    const resp = await fetch(`${PY_SERVICE_URL}/sam/segment`, { method: 'POST', body: JSON.stringify(req.body), headers: { 'Content-Type': 'application/json' } });
    const data = await resp.json();
    if (!resp.ok) logProxy('sam/segment', { status: resp.status, data });
    return res.status(resp.status).json(data);
  } catch (e) { console.error('[proxy sam/segment] error', e); return res.status(500).json({ error: 'proxy error', detail: String(e) }); }
});

app.post('/api/sam/save_component', express.json(), async (req, res) => {
  try {
    const resp = await fetch(`${PY_SERVICE_URL}/sam/save_component`, { method: 'POST', body: JSON.stringify(req.body), headers: { 'Content-Type': 'application/json' } });
    const data = await resp.json();
    if (!resp.ok) logProxy('sam/save_component', { status: resp.status, data });
    return res.status(resp.status).json(data);
  } catch (e) { console.error('[proxy sam/save_component] error', e); return res.status(500).json({ error: 'proxy error', detail: String(e) }); }
});

app.get('/api/sam/components', async (req, res) => {
  try {
    const url = new URL(`${PY_SERVICE_URL}/sam/components`);
    if (req.query.image_id) url.searchParams.set('image_id', req.query.image_id);
    const resp = await fetch(url, { method: 'GET' });
    const data = await resp.json();
    if (!resp.ok) logProxy('sam/components', { status: resp.status, data });
    return res.status(resp.status).json(data);
  } catch (e) { console.error('[proxy sam/components] error', e); return res.status(500).json({ error: 'proxy error', detail: String(e) }); }
});

app.post('/api/sam/apply', express.json(), async (req, res) => {
  try {
    const resp = await fetch(`${PY_SERVICE_URL}/sam/apply`, { method: 'POST', body: JSON.stringify(req.body), headers: { 'Content-Type': 'application/json' } });
    const data = await resp.json();
    if (!resp.ok) logProxy('sam/apply', { status: resp.status, data });
    return res.status(resp.status).json(data);
  } catch (e) { console.error('[proxy sam/apply] error', e); return res.status(500).json({ error: 'proxy error', detail: String(e) }); }
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
    let data;
    const ct = resp.headers.get('content-type') || '';
    try {
      if (ct.includes('application/json')) {
        data = await resp.json();
      } else {
        const text = await resp.text();
        data = { raw: text };
      }
    } catch (parseErr) {
      data = { parse_error: String(parseErr) };
    }
    if (!resp.ok) {
      logProxy('dataset/init', { status: resp.status, data });
      return res.status(resp.status).json({ error: 'backend_failed', backend_status: resp.status, backend: data });
    }
    return res.status(resp.status).json(data);
  } catch (e) {
    console.error('[dataset/init proxy] error', e);
    return res.status(500).json({ error: 'proxy_error', detail: String(e) });
  }
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
      logProxy('dataset/apply_stream', { status: pyResp.status, data: errData });
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
    if (!resp.ok) logProxy('dataset/point_preview', { status: resp.status, data });
    return res.status(resp.status).json(data);
  } catch (e) { console.error('[proxy dataset/point_preview] error', e); return res.status(500).json({ error: 'proxy error', detail: String(e) }); }
});

// Template preview (before generation)
app.post('/api/sam/dataset/template/preview', express.json(), async (req, res) => {
  try {
    const resp = await fetch(`${PY_SERVICE_URL}/sam/dataset/template/preview`, { method: 'POST', body: JSON.stringify(req.body), headers: { 'Content-Type': 'application/json' } });
    const data = await resp.json();
    if (!resp.ok) logProxy('dataset/template/preview', { status: resp.status, data });
    return res.status(resp.status).json(data);
  } catch (e) { console.error('[proxy dataset/template/preview] error', e); return res.status(500).json({ error: 'proxy error', detail: String(e) }); }
});

// Backend health proxy for quick ECS debugging
app.get('/api/backend/health', async (_req, res) => {
  try {
    const r = await fetch(`${PY_SERVICE_URL}/health`);
    const txt = await r.text();
    return res.status(r.status).json({ backend_status: r.status, raw: txt });
  } catch (e) {
    return res.status(500).json({ error: 'backend_unreachable', detail: String(e) });
  }
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
