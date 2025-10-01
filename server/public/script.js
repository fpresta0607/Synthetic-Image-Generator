const imageInput = document.getElementById('imageInput');
const samPanel = document.getElementById('samPanel');
const samInitBtn = document.getElementById('samInitBtn');
const samUndoBtn = document.getElementById('samUndoBtn');
const samClearBtn = document.getElementById('samClearBtn');
const samRefreshBtn = document.getElementById('samRefreshBtn');
const samStatus = document.getElementById('samStatus');
const samImg = document.getElementById('samImg');
const samOverlay = document.getElementById('samOverlay');
const samPointsCanvas = document.getElementById('samPointsCanvas');
const samCandidates = document.getElementById('samCandidates');
const samComponentName = document.getElementById('samComponentName');
const samSaveBtn = document.getElementById('samSaveBtn');
const samComponentsPanel = document.getElementById('samComponentsPanel');
const samSavedList = document.getElementById('samSavedList');
const samEditsList = document.getElementById('samEditsList');
const samApplyBtn = document.getElementById('samApplyBtn');
const samDownloadBtn = document.getElementById('samDownloadBtn');
const samApplyStatus = document.getElementById('samApplyStatus');
const samEditedImg = document.getElementById('samEditedImg');
const helpBox = document.getElementById('helpBox');
const samPointSummary = document.getElementById('samPointSummary');

let currentFile = null;
// SAM state
let samImageId = null;
let samPoints = []; // {x,y,positive}
let samCandidatesData = [];
let samActiveCandidate = null; // object from candidates
let samSavedComponents = []; // {id,bbox,area,score,name}
let samActiveSaved = null; // component id
let samEditsMap = {}; // component_id -> edits object

// Utility: update contextual help
function setHelp(msg){ if(helpBox) helpBox.textContent = msg; }

imageInput.addEventListener('change', () => {
  const file = imageInput.files[0];
  if(!file) return;
  currentFile = file;
  resetSamState();
  samInitBtn.disabled = false;
  samStatus.textContent = 'Ready';
  setHelp('Click Init SAM to embed the image.');
});

// Removed classic segmentation logic

// ------------------------- SAM Logic ----------------------------
function resetSamState(){
  samImageId = null;
  samPoints = [];
  samCandidatesData = [];
  samActiveCandidate = null;
  samSavedComponents = [];
  samActiveSaved = null;
  samEditsMap = {};
  samImg.src = '';
  samOverlay.getContext('2d').clearRect(0,0,samOverlay.width,samOverlay.height);
  samPointsCanvas.getContext('2d').clearRect(0,0,samPointsCanvas.width,samPointsCanvas.height);
  samCandidates.innerHTML='';
  samSavedList.innerHTML='';
  samEditsList.innerHTML='';
  samApplyBtn.disabled = true;
  samDownloadBtn.disabled = true;
  samSaveBtn.disabled = true;
  samUndoBtn.disabled = true;
  samClearBtn.disabled = true;
  samRefreshBtn.disabled = true;
  setHelp('Init SAM to begin placing points.');
}

async function samInit(){
  if(!currentFile) return;
  samStatus.textContent = 'Initializing...'; setHelp('Loading model & embedding image...');
  const form = new FormData();
  form.append('image', currentFile);
  try {
    const resp = await fetch('/api/sam/init', { method:'POST', body: form });
    const data = await resp.json();
    if(!resp.ok){ samStatus.textContent = data.error || 'Init failed'; return; }
    samImageId = data.image_id;
    samImg.src = URL.createObjectURL(currentFile);
    // Setup canvases size after image loads
    samImg.onload = ()=>{ resizeSamCanvases(); drawSamPoints(); };
  samStatus.textContent = 'Image ready';
  setHelp('Click up to 3 positive points (left). Use right / Shift+Click for negatives.');
    enableSamButtons();
  } catch(e){ console.error(e); samStatus.textContent='Init error'; }
}

function enableSamButtons(){
  samUndoBtn.disabled = samPoints.length===0;
  samClearBtn.disabled = samPoints.length===0;
  samRefreshBtn.disabled = samPoints.length===0;
  samInitBtn.disabled = !!samImageId;
}

function resizeSamCanvases(){
  [samOverlay, samPointsCanvas].forEach(c=>{ c.width = samImg.clientWidth; c.height = samImg.clientHeight; });
}
window.addEventListener('resize', ()=>{ if(!samPanel.hidden) { resizeSamCanvases(); drawSamPoints(); drawSamCandidate(); }});

function addSamPoint(x,y,positive){
  samPoints.push({x,y,positive});
  if(samPoints.length>3) samPoints.shift(); // keep last 3 for responsiveness
  drawSamPoints();
  enableSamButtons();
  samSegment();
  setHelp('Select the best mask from the list.');
}

function undoSamPoint(){
  samPoints.pop();
  drawSamPoints();
  enableSamButtons();
  if(samPoints.length) samSegment(); else { samCandidates.innerHTML=''; clearSamOverlays(); }
  setHelp(samPoints.length? 'Updated points – masks refreshing.' : 'No points left. Add points to get masks.');
}

function clearSamPoints(){
  samPoints=[]; samCandidates.innerHTML='<li class="empty">Add points to see masks.</li>'; samActiveCandidate=null; drawSamPoints(); clearSamOverlays(); enableSamButtons(); samSaveBtn.disabled=true; setHelp('Points cleared. Add new points.'); }

function clearSamOverlays(){
  samOverlay.getContext('2d').clearRect(0,0,samOverlay.width,samOverlay.height);
}

function drawSamPoints(){
  const ctx = samPointsCanvas.getContext('2d');
  ctx.clearRect(0,0,samPointsCanvas.width,samPointsCanvas.height);
  if(!samImg.naturalWidth) return;
  const scaleX = samImg.clientWidth / samImg.naturalWidth;
  const scaleY = samImg.clientHeight / samImg.naturalHeight;
  for(const p of samPoints){
    ctx.beginPath();
    ctx.fillStyle = p.positive? '#10b981':'#ef4444';
    ctx.arc(p.x*scaleX, p.y*scaleY, 5, 0, Math.PI*2);
    ctx.fill();
    ctx.strokeStyle='#000'; ctx.lineWidth=2; ctx.stroke();
  }
}

async function samSegment(){
  if(!samImageId || !samPoints.length) return;
  samStatus.textContent='Segmenting...'; setHelp('Generating up to 3 mask proposals.');
  try {
    const payload = { image_id: samImageId, points: samPoints, accumulate: false, top_k:3 };
    const resp = await fetch('/api/sam/segment', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(payload) });
    const data = await resp.json();
    if(!resp.ok){ samStatus.textContent=data.error||'Segmentation failed'; return; }
    samCandidatesData = data.candidates || [];
    if(data.point_summary && samPointSummary){
      const ps = data.point_summary;
      samPointSummary.textContent = `${ps.positive}+ / ${ps.negative}-`; }
    renderSamCandidates();
    samStatus.textContent = 'Candidates ready'; setHelp('Click a candidate to preview.');
  } catch(e){ console.error(e); samStatus.textContent='Segment error'; }
}

function renderSamCandidates(){
  samCandidates.innerHTML='';
  samCandidatesData.forEach(c=>{
    const li = document.createElement('li');
    li.dataset.rank=c.rank;
    // Show area; if a prior candidate existed with same rank earlier, compute delta for quick visual reference
    let delta = '';
    if(window._lastAreas && window._lastAreas[c.rank]){
      const prev = window._lastAreas[c.rank];
      const diff = c.area - prev;
      if(diff !== 0){
        const sign = diff>0? '+' : '';
        delta = `<span class="delta" style="color:${diff>0?'#10b981':'#ef4444'}">${sign}${diff}</span>`;
      }
    }
    li.innerHTML = `<span>#${c.rank}</span><span class="score">${c.score.toFixed(3)}</span><span>${c.area}</span>${delta}`;
    li.addEventListener('click', ()=> selectSamCandidate(c.rank));
    samCandidates.appendChild(li);
  });
  // Store current areas for next comparison
  window._lastAreas = Object.fromEntries(samCandidatesData.map(c=>[c.rank, c.area]));
  if(samCandidatesData.length){ selectSamCandidate(1); }
}

function selectSamCandidate(rank){
  samActiveCandidate = samCandidatesData.find(c=>c.rank===rank);
  [...samCandidates.children].forEach(li=> li.classList.toggle('active', parseInt(li.dataset.rank,10)===rank));
  drawSamCandidate();
  samSaveBtn.disabled = !samActiveCandidate;
  if(samActiveCandidate) setHelp('Optionally name the component then Save.');
}

function drawSamCandidate(){
  clearSamOverlays();
  if(!samActiveCandidate) return;
  const ctx = samOverlay.getContext('2d');
  const img = new Image();
  img.onload = ()=>{
    samOverlay.width = samImg.clientWidth; samOverlay.height = samImg.clientHeight;
    const scaleX = samImg.clientWidth / img.width; const scaleY = samImg.clientHeight / img.height;
    ctx.globalAlpha = 0.35; ctx.drawImage(img,0,0,img.width,img.height,0,0,img.width*scaleX,img.height*scaleY); ctx.globalAlpha=1;
    ctx.strokeStyle='#3b82f6'; ctx.lineWidth=2; ctx.setLineDash([6,4]);
    // Derive bbox from candidate
    const b = samActiveCandidate.bbox;
    ctx.strokeRect(b[0]*scaleX, b[1]*scaleY, (b[2]-b[0])*scaleX, (b[3]-b[1])*scaleY);
  };
  img.src = 'data:image/png;base64,'+samActiveCandidate.mask_png;
}

samInitBtn.addEventListener('click', samInit);
samUndoBtn.addEventListener('click', undoSamPoint);
samClearBtn.addEventListener('click', clearSamPoints);
samRefreshBtn.addEventListener('click', samSegment);

samImg.addEventListener('contextmenu', e=> e.preventDefault());
samImg.addEventListener('click', e => handleSamClick(e, true));
samImg.addEventListener('mousedown', e => { if(e.button===2) handleSamClick(e,false); });
samImg.addEventListener('mousemove', ()=>{});
window.addEventListener('keydown', e=>{
  if(samPanel.hidden) return;
  if(e.key==='u' || (e.ctrlKey && e.key==='z')) { undoSamPoint(); }
  if(e.key==='Escape'){ clearSamPoints(); }
  if(e.key==='1') selectSamCandidate(1);
  if(e.key==='2') selectSamCandidate(2);
  if(e.key==='3') selectSamCandidate(3);
});

function handleSamClick(e, positive){
  if(!samImageId) return;
  const rect = samImg.getBoundingClientRect();
  const x = (e.clientX - rect.left) * (samImg.naturalWidth / rect.width);
  const y = (e.clientY - rect.top) * (samImg.naturalHeight / rect.height);
  addSamPoint(Math.round(x), Math.round(y), positive && !e.shiftKey);
}

samSaveBtn.addEventListener('click', async ()=>{
  if(!samActiveCandidate || !samImageId) return;
  const name = samComponentName.value.trim() || undefined;
  const payload = { image_id: samImageId, mask_png: samActiveCandidate.mask_png, score: samActiveCandidate.score, name };
  try {
    const resp = await fetch('/api/sam/save_component', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(payload) });
    const data = await resp.json();
    if(!resp.ok){ samStatus.textContent = data.error || 'Save failed'; return; }
  samStatus.textContent = 'Component saved'; setHelp('Component stored. Adjust sliders below or add more components.');
    samComponentName.value='';
    loadSamComponents();
  } catch(e){ console.error(e); samStatus.textContent='Save error'; }
});

async function loadSamComponents(){
  if(!samImageId) return;
  try {
    const resp = await fetch(`/api/sam/components?image_id=${samImageId}`);
    const data = await resp.json();
    if(!resp.ok){ samComponentsPanel.hidden=true; return; }
    samSavedComponents = data.components || [];
    renderSamSavedComponents();
    samComponentsPanel.hidden = samSavedComponents.length===0;
  } catch(e){ console.error(e); }
}

function renderSamSavedComponents(){
  samSavedList.innerHTML='';
  samSavedComponents.forEach(c=>{
    const chip = document.createElement('div');
    chip.className='chip';
    chip.textContent = `${c.name||'comp_'+c.id} (${c.id})`;
    chip.addEventListener('click', ()=> selectSamSaved(c.id));
    if(c.id===samActiveSaved) chip.classList.add('active');
    samSavedList.appendChild(chip);
  });
  if(!samActiveSaved && samSavedComponents.length){ selectSamSaved(samSavedComponents[0].id); }
}

function selectSamSaved(id){
  samActiveSaved = id;
  renderSamSavedComponents();
  buildSamEdits();
}

function buildSamEdits(){
  samEditsList.innerHTML='';
  if(!samActiveSaved) { samApplyBtn.disabled=true; return; }
  const fields = [
    {key:'brightness', label:'Brightness', min:-1, max:1, step:0.02, def:0},
    {key:'contrast', label:'Contrast', min:-1, max:1, step:0.02, def:0},
    {key:'gamma', label:'Gamma', min:-0.9, max:2, step:0.05, def:0},
    {key:'hue', label:'Hue', min:-180, max:180, step:1, def:0},
    {key:'saturation', label:'Sat', min:-1, max:3, step:0.05, def:0},
    {key:'sharpen', label:'Sharpen', min:0, max:2, step:0.1, def:0},
    {key:'noise', label:'Noise', min:0, max:0.2, step:0.01, def:0}
  ];
  const state = samEditsMap[samActiveSaved] || {}; samEditsMap[samActiveSaved]=state;
  fields.forEach(f=>{
    const val = (f.key in state)? state[f.key]: f.def;
    const wrap = document.createElement('label');
    wrap.innerHTML = `${f.label}<input type="range" data-field="${f.key}" value="${val}" min="${f.min}" max="${f.max}" step="${f.step}" /><input type="number" data-sync-field="${f.key}" value="${val}" min="${f.min}" max="${f.max}" step="${f.step}" />`;
    samEditsList.appendChild(wrap);
  });
  samApplyBtn.disabled=false;
  setHelp('Tweak sliders, then Apply to see result.');
}

samEditsList.addEventListener('input', e=>{
  const t = e.target;
  if(t.matches('input[data-field]')){
    const field = t.dataset.field; const num = samEditsList.querySelector(`input[data-sync-field="${field}"]`); if(num) num.value = t.value;
    if(!samEditsMap[samActiveSaved]) samEditsMap[samActiveSaved]={};
    samEditsMap[samActiveSaved][field] = parseFloat(t.value);
  } else if(t.matches('input[data-sync-field]')){
    const field = t.dataset.syncField; const range = samEditsList.querySelector(`input[data-field="${field}"]`); if(range) range.value = t.value;
    if(!samEditsMap[samActiveSaved]) samEditsMap[samActiveSaved]={};
    samEditsMap[samActiveSaved][field] = parseFloat(t.value);
  }
});

samApplyBtn.addEventListener('click', async ()=>{
  if(!samImageId || !samSavedComponents.length) return;
  samApplyStatus.textContent='Applying...';
  try {
  const edits = Object.entries(samEditsMap).map(([cid,vals])=>({ component_id: parseInt(cid,10), ...vals }));
    const payload = { image_id: samImageId, edits, export_mask: (edits.length===1) };
    const resp = await fetch('/api/sam/apply', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(payload) });
    const data = await resp.json();
    if(!resp.ok){ samApplyStatus.textContent = data.error || 'Apply failed'; return; }
    samApplyStatus.textContent='Done';
    if(data.variant_png){ samEditedImg.src='data:image/png;base64,'+data.variant_png; samDownloadBtn.disabled=