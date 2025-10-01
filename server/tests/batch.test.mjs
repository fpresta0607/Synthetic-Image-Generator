import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import multer from 'multer';
import fetch from 'node-fetch';
import FormData from 'form-data';
import supertest from 'supertest';

// We test proxy layer endpoints against a mocked Python backend.

const PY_PORT = 5999;
let pyServer, nodeServer, requestAgent;

function startMockPython(){
  const app = express();
  const upload = multer();
  app.post('/sam/batch_process', upload.array('images'), (req,res)=>{
    const mode = req.body.mode || 'full';
    const edits = req.body.edits;
    return res.json({
      mock:true,
      received:{ mode, count:(req.files||[]).length, hasEdits: !!edits },
      results:(req.files||[]).map(f=>({ filename:f.originalname, variant_png:'BASE64PNG', mode }))
    });
  });
  app.post('/sam/batch_process_stream', upload.array('images'), (req,res)=>{
    res.setHeader('Content-Type','text/event-stream');
    // Emit two fake events then DONE
    (req.files||[]).forEach((f,i)=>{
      res.write(`data: ${JSON.stringify({ filename:f.originalname, variant_png:'BASE64PNG', mode:req.body.mode||'full' })}\n\n`);
    });
    res.write('data: [DONE]\n\n');
    res.end();
  });
  app.post('/sam/dataset/init', upload.array('images'), (req,res)=>{
    return res.json({ dataset_id:'ds123', count:(req.files||[]).length });
  });
  app.post('/sam/dataset/template/save', express.json(), (req,res)=>{
    const { dataset_id, image_filename, points=[] } = req.body || {};
    return res.json({ template_id:'tpl1', dataset_id, image_filename, points_count: points.length });
  });
  app.get('/sam/dataset/templates', (req,res)=>{
    return res.json({ templates:[{ template_id:'tpl1', name:'t1'}] });
  });
  app.post('/sam/dataset/apply_stream', express.json(), (req,res)=>{
    res.setHeader('Content-Type','text/event-stream');
    res.write(`data: ${JSON.stringify({ filename:'imgA.png', variant_png:'BASE64PNG' })}\n\n`);
    res.write('data: [DONE]\n\n');
    res.end();
  });
  return new Promise(resolve=>{ const s = app.listen(PY_PORT, ()=> resolve(s)); });
}

async function startNodeProxy(){
  process.env.PY_SERVICE_URL = `http://localhost:${PY_PORT}`;
  process.env.NODE_ENV = 'test';
  const { default: app } = await import('../server.js');
  return new Promise(resolve=>{ const s = app.listen(0, ()=> resolve(s)); });
}

function makeAgent(server){
  const { port } = server.address();
  return supertest(`http://localhost:${port}`);
}

// Setup once
test.before(async () => {
  pyServer = await startMockPython();
  nodeServer = await startNodeProxy();
  requestAgent = makeAgent(nodeServer);
});

// Teardown
test.after(() => {
  try { pyServer && pyServer.close(); } catch{}
  try { nodeServer && nodeServer.close(); } catch{}
});

// --- Tests ---

test('batch_process forwards images and mode', async () => {
  const resp = await requestAgent
    .post('/api/sam/batch_process')
    .field('mode','center_point')
    .attach('images', Buffer.from('fakeimg1'), 'a.jpg')
    .attach('images', Buffer.from('fakeimg2'), 'b.png');
  assert.equal(resp.status, 200);
  assert.equal(resp.body.mock, true);
  assert.equal(resp.body.received.mode, 'center_point');
  assert.equal(resp.body.received.count, 2);
  assert.equal(resp.body.results.length, 2);
});

test('batch_process includes edits JSON when provided', async () => {
  const resp = await requestAgent
    .post('/api/sam/batch_process')
    .field('mode','full')
    .field('edits', JSON.stringify({ brightness: 0.2 }))
    .attach('images', Buffer.from('x'), 'one.jpg');
  assert.equal(resp.status, 200);
  assert.equal(resp.body.received.hasEdits, true);
  assert.equal(resp.body.received.count, 1);
});

test('batch_process_stream streams multiple results then DONE', async () => {
  const resp = await requestAgent
    .post('/api/sam/batch_process_stream')
    .field('mode','full')
    .attach('images', Buffer.from('x1'), 'one.jpg')
    .attach('images', Buffer.from('x2'), 'two.jpg');
  assert.equal(resp.status, 200);
  // Raw text/event-stream body captured as text
  const text = resp.text;
  assert.match(text, /data: .*one.jpg/);
  assert.match(text, /data: .*two.jpg/);
  assert.match(text, /data: \[DONE\]/);
});

test('dataset init returns dataset_id', async () => {
  const resp = await requestAgent
    .post('/api/sam/dataset/init')
    .attach('images', Buffer.from('a'), 'a.png')
    .attach('images', Buffer.from('b'), 'b.png');
  assert.equal(resp.status, 200);
  assert.equal(resp.body.dataset_id, 'ds123');
  assert.equal(resp.body.count, 2);
});

test('dataset template save echoes structure', async () => {
  const payload = { dataset_id:'ds123', image_filename:'a.png', points:[{ x_norm:0.5, y_norm:0.5, positive:true }] };
  const resp = await requestAgent
    .post('/api/sam/dataset/template/save')
    .send(payload)
    .set('Content-Type','application/json');
  assert.equal(resp.status, 200);
  assert.equal(resp.body.template_id, 'tpl1');
  assert.equal(resp.body.points_count, 1);
});

test('dataset templates list returns templates', async () => {
  const resp = await requestAgent.get('/api/sam/dataset/templates?dataset_id=ds123');
  assert.equal(resp.status, 200);
  assert.ok(Array.isArray(resp.body.templates));
  assert.equal(resp.body.templates[0].template_id, 'tpl1');
});

test('dataset apply_stream returns streaming DONE', async () => {
  const resp = await requestAgent
    .post('/api/sam/dataset/apply_stream')
    .send({ dataset_id:'ds123', templates:[{ template_id:'tpl1', edits:{ brightness:0.1 }}] })
    .set('Content-Type','application/json');
  assert.equal(resp.status, 200);
  assert.match(resp.text, /data: .*imgA.png/);
  assert.match(resp.text, /data: \[DONE\]/);
});
