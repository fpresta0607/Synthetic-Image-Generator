// Dataset Workflow State
let datasetState = {
  datasetId: null,
  images: [],
  templates: [],
  currentReferenceFile: null,
  currentReferenceFilename: null,
  currentPoints: [],
  results: []
};

// DOM Elements
const helpContent = document.getElementById("helpContent");
const phaseLabel = document.getElementById("phaseLabel");
const stepDataset = document.getElementById("stepDataset");
const datasetImages = document.getElementById("datasetImages");
const datasetInitBtn = document.getElementById("datasetInitBtn");
const datasetStatus = document.getElementById("datasetStatus");
const datasetPreview = document.getElementById("datasetPreview");
const stepTemplate = document.getElementById("stepTemplate");
const templateAddBtn = document.getElementById("templateAddBtn");
const templateStatus = document.getElementById("templateStatus");
// Reference galleries (separate fail / pass)
const referenceGalleryFail = document.getElementById("referenceGalleryFail");
const referenceGalleryPass = document.getElementById("referenceGalleryPass");
const pointCaptureBlock = document.getElementById("pointCaptureBlock");
const templatePreviewContainer = document.getElementById("templatePreviewContainer");
const templateImg = document.getElementById("templateImg");
const templatePointsCanvas = document.getElementById("templatePointsCanvas");
const templateMaskCanvas = document.getElementById("templateMaskCanvas");
const templateName = document.getElementById("templateName");
const templateClass = document.getElementById("templateClass");
const templateSaveBtn = document.getElementById("templateSaveBtn");
const templateClearBtn = document.getElementById("templateClearBtn");
const templatePreviewBtn = document.getElementById("templatePreviewBtn");
const pointCount = document.getElementById("pointCount");
const templateList = document.getElementById("templateList");
const proceedToEditsBtn = document.getElementById("proceedToEditsBtn");
const stepGenerate = document.getElementById("stepGenerate");
const templateEditsList = document.getElementById("templateEditsList");
const generateBtn = document.getElementById("generateBtn");
const backlightToggle = document.getElementById("backlightToggle");

function isElementInStep(stepEl){
  return stepEl && !stepEl.hasAttribute('hidden');
}
const generateStatus = document.getElementById("generateStatus");
const generateResults = document.getElementById("generateResults");
const downloadAllBtn = document.getElementById("downloadAllBtn");
const backToTemplates = document.getElementById("backToTemplates");
const templatePreviewSection = document.getElementById("templatePreviewSection");
const previewClassFilter = document.getElementById("previewClassFilter");
const previewTemplateBtn = document.getElementById("previewTemplateBtn");
const previewStatus = document.getElementById("previewStatus");
const previewResultImg = document.getElementById("previewResultImg");
const previewPlaceholder = document.getElementById("previewPlaceholder");

// Modal elements
const generationModal = document.getElementById("generationModal");
const modalProgressCount = document.getElementById("modalProgressCount");
const modalProgressBar = document.getElementById("modalProgressBar");
const modalProgressPercent = document.getElementById("modalProgressPercent");
const modalStatusTitle = document.getElementById("modalStatusTitle");
const modalStatusSubtitle = document.getElementById("modalStatusSubtitle");
const currentImageSection = document.getElementById("currentImageSection");
const currentImageName = document.getElementById("currentImageName");
const modalMinimizeBtn = document.getElementById("modalMinimizeBtn");
const modalCancelBtn = document.getElementById("modalCancelBtn");
const minimizedProgress = document.getElementById("minimizedProgress");
const minimizedCount = document.getElementById("minimizedCount");
const minimizedExpandBtn = document.getElementById("minimizedExpandBtn");

let isGenerationCancelled = false;

function showGenerationModal() {
  generationModal.hidden = false;
  minimizedProgress.hidden = true;
  isGenerationCancelled = false;
  updateModalProgress(0, datasetState.images.length);
}

function hideGenerationModal() {
  generationModal.hidden = true;
  minimizedProgress.hidden = true;
}

function minimizeModal() {
  generationModal.hidden = true;
  minimizedProgress.hidden = false;
}

function expandModal() {
  generationModal.hidden = false;
  minimizedProgress.hidden = true;
}

function updateModalProgress(current, total) {
  const percentage = total > 0 ? Math.round((current / total) * 100) : 0;
  modalProgressCount.textContent = `${current} / ${total}`;
  modalProgressBar.style.width = `${percentage}%`;
  modalProgressPercent.textContent = `${percentage}%`;
  minimizedCount.textContent = `${current}/${total}`;
  
  if (current > 0 && current < total) {
    currentImageSection.hidden = false;
  }
}

function updateModalStatus(title, subtitle) {
  modalStatusTitle.textContent = title;
  if (subtitle) {
    modalStatusSubtitle.textContent = subtitle;
  }
}

function setModalComplete() {
  updateModalStatus("Generation Complete!", "Your dataset variants are ready");
  modalCancelBtn.textContent = "Close";
  currentImageSection.hidden = true;
}

// Modal event listeners
modalMinimizeBtn.addEventListener("click", minimizeModal);
minimizedExpandBtn.addEventListener("click", expandModal);

modalCancelBtn.addEventListener("click", () => {
  if (modalCancelBtn.textContent === "Close") {
    hideGenerationModal();
  } else {
    isGenerationCancelled = true;
    updateModalStatus("Cancelling...", "Stopping generation");
    modalCancelBtn.disabled = true;
  }
});

function showStep(step) {
  [stepDataset, stepTemplate, stepGenerate].forEach(s => {
    s.hidden = s !== step;
    s.classList.toggle("active", s === step);
  });
  if (step === stepDataset) {
    phaseLabel.textContent = "Upload Dataset";
    helpContent.textContent = "Upload multiple images to initialize a dataset.";
  } else if (step === stepTemplate) {
    phaseLabel.textContent = "Capture Templates";
    helpContent.textContent = "Select reference images and add point prompts to create templates.";
  } else if (step === stepGenerate) {
    phaseLabel.textContent = "Generate";
    helpContent.textContent = "Configure edits per template and generate all variants.";
  }
}

// Step 1: Dataset Upload
datasetImages.addEventListener("change", () => {
  const files = Array.from(datasetImages.files);
  if (!files.length) return;
  datasetState.images = files.map(f => ({ filename: f.name, file: f }));
  datasetInitBtn.disabled = false;
  datasetStatus.textContent = `${files.length} image(s) ready`;
  renderDatasetPreview();
});

function renderDatasetPreview() {
  datasetPreview.innerHTML = "";
  datasetState.images.slice(0, 6).forEach(img => {
    const thumb = document.createElement("div");
    thumb.className = "dataset-thumb";
    const imgEl = document.createElement("img");
    imgEl.src = URL.createObjectURL(img.file);
    imgEl.alt = img.filename;
    thumb.appendChild(imgEl);
    const label = document.createElement("span");
    label.textContent = img.filename;
    thumb.appendChild(label);
    datasetPreview.appendChild(thumb);
  });
  if (datasetState.images.length > 6) {
    const more = document.createElement("div");
    more.className = "dataset-thumb more";
    more.textContent = `+${datasetState.images.length - 6} more`;
    datasetPreview.appendChild(more);
  }
}

datasetInitBtn.addEventListener("click", async () => {
  datasetStatus.textContent = "Initializing...";
  datasetInitBtn.disabled = true;
  const form = new FormData();
  datasetState.images.forEach(img => form.append("images", img.file));
  try {
    const resp = await fetch("/api/sam/dataset/init", { method: "POST", body: form });
    const data = await resp.json();
    if (!resp.ok) {
      datasetStatus.textContent = data.error || "Init failed";
      datasetInitBtn.disabled = false;
      return;
    }
    datasetState.datasetId = data.dataset_id;
    // Store image metadata from backend (includes IDs)
    if (data.images) {
      datasetState.images = datasetState.images.map((img, idx) => {
        const backendImg = data.images.find(bi => bi.filename === img.filename) || data.images[idx];
        return { ...img, id: backendImg?.id, filename: img.filename };
      });
    }
    
    // Show duplicate detection message if any
    if (data.duplicates_found && data.duplicates_found > 0) {
      datasetStatus.textContent = `✓ ${data.duplicates_message}`;
      datasetStatus.style.color = '#5dade2';
    }
    
    // Pre-warm cache to speed up first requests by 10-20x
    const prewarmProgress = document.getElementById("prewarmProgress");
    const prewarmTitle = document.getElementById("prewarmTitle");
    const prewarmSubtitle = document.getElementById("prewarmSubtitle");
    
    prewarmProgress.style.display = "flex";
    prewarmTitle.textContent = `Pre-warming cache (${data.images.length} images)...`;
    prewarmSubtitle.textContent = "Estimated time: calculating...";
    
    try {
      const prewarmResp = await fetch("/api/sam/dataset/prewarm", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ dataset_id: data.dataset_id })
      });
      
      if (prewarmResp.ok) {
        const reader = prewarmResp.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";
        let startTime = Date.now();
        let avgTimePerImage = 0;
        
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          
          buffer += decoder.decode(value, { stream: true });
          const parts = buffer.split(/\n\n/);
          buffer = parts.pop() || "";
          
          for (const chunk of parts) {
            const line = chunk.trim();
            if (!line.startsWith("data:")) continue;
            const payloadStr = line.slice(5).trim();
            try {
              const obj = JSON.parse(payloadStr);
              if (obj.done) {
                prewarmProgress.style.display = "none";
                let msg = `Dataset ready (cache: ${obj.cache_size} embeddings`;
                if (obj.computed !== undefined && obj.skipped !== undefined) {
                  msg += `, computed: ${obj.computed}, skipped: ${obj.skipped}`;
                }
                msg += ')';
                datasetStatus.textContent = msg;
              } else if (obj.index !== undefined) {
                const completed = obj.index + 1;
                const total = obj.total;
                const elapsed = Date.now() - startTime;
                
                // Calculate average time per image (only for computed ones)
                if (!obj.skipped) {
                  avgTimePerImage = elapsed / completed;
                }
                const remaining = total - completed;
                const estimatedMs = remaining * avgTimePerImage;
                
                // Format time remaining
                let timeStr = "";
                if (estimatedMs < 60000) {
                  timeStr = `${Math.ceil(estimatedMs / 1000)}s`;
                } else {
                  const mins = Math.floor(estimatedMs / 60000);
                  const secs = Math.ceil((estimatedMs % 60000) / 1000);
                  timeStr = `${mins}m ${secs}s`;
                }
                
                const statusIcon = obj.skipped ? '⚡' : '⏳';
                const action = obj.skipped ? 'skipped (cached)' : 'computing';
                prewarmTitle.textContent = `${statusIcon} Pre-warming cache... ${completed}/${total}`;
                prewarmSubtitle.textContent = `${action} • Est. remaining: ${timeStr} (avg ${(avgTimePerImage / 1000).toFixed(1)}s per image)`;
              }
            } catch (e) {
              /* ignore partial JSON */
            }
          }
        }
      }
    } catch (e) {
      console.warn("Prewarm failed, continuing:", e);
      prewarmProgress.style.display = "none";
      datasetStatus.textContent = `Dataset ${data.dataset_id} ready`;
    }
    
    showStep(stepTemplate);
    renderReferenceGallery();
  } catch (e) {
    console.error(e);
    if (e.message && e.message.includes("Failed to fetch")) {
      datasetStatus.textContent = "Backend not ready - wait 10s and retry";
    } else {
      datasetStatus.textContent = "Error: " + (e.message || "Unknown");
    }
    datasetInitBtn.disabled = false;
  }
});

// Step 2: Template Capture
function renderReferenceGallery() {
  if (!referenceGalleryFail || !referenceGalleryPass) return;
  referenceGalleryFail.innerHTML = "";
  referenceGalleryPass.innerHTML = "";
  // Expanded heuristic sets (tunable)
  const FAIL_KEYS = ['fail','bad','defect','error','reject','ng'];
  const PASS_KEYS = ['pass','ok','good','clean','normal','baseline'];
  const failImgs = [];
  const passImgs = [];
  // Scan all images until both buckets filled (up to 5 each)
  for (const img of datasetState.images) {
    const lower = img.filename.toLowerCase();
    let tagged = false;
    if (FAIL_KEYS.some(k => lower.includes(k))) { failImgs.push(img); tagged = true; }
    else if (PASS_KEYS.some(k => lower.includes(k))) { passImgs.push(img); tagged = true; }
    if (!tagged) {
      // If ambiguous, prefer pass bucket unless already full
      (passImgs.length < 5 ? passImgs : failImgs).push(img);
    }
    if (failImgs.length >= 5 && passImgs.length >= 5) break;
  }
  const build = (list, target) => {
    list.slice(0,5).forEach(img => {
      const card = document.createElement("div");
      card.className = "reference-card";
      const imgEl = document.createElement("img");
      imgEl.src = URL.createObjectURL(img.file);
      imgEl.alt = img.filename;
      card.appendChild(imgEl);
      const label = document.createElement("span");
      label.textContent = img.filename;
      card.appendChild(label);
      card.addEventListener("click", (e) => selectReference(img, e.currentTarget));
      target.appendChild(card);
    });
  };
  build(failImgs, referenceGalleryFail);
  build(passImgs, referenceGalleryPass);
  templateAddBtn.disabled = false;
}

function selectReference(img, cardEl) {
  datasetState.currentReferenceFile = img.file;
  datasetState.currentReferenceFilename = img.filename;
  datasetState.currentReferenceId = img.id;
  datasetState.currentPoints = [];
  pointCaptureBlock.hidden = false;
  templateImg.src = URL.createObjectURL(img.file);
  templateImg.onload = () => {
    resizeTemplateCanvas();
    drawTemplatePoints();
  };
  templateSaveBtn.disabled = true;
  templateClearBtn.disabled = true;
  pointCount.textContent = "";
  templateStatus.textContent = `Adding points to ${img.filename}`;
  // Clear active across both galleries
  [ ...(referenceGalleryFail?.children || []), ...(referenceGalleryPass?.children || []) ].forEach(c => c.classList.remove("active"));
  if (cardEl) cardEl.classList.add("active");
}

function resizeTemplateCanvas() {
  const displayWidth = templateImg.clientWidth;
  const displayHeight = templateImg.clientHeight;
  // Use natural dimensions for canvas size to match actual image resolution
  const naturalWidth = templateImg.naturalWidth || displayWidth;
  const naturalHeight = templateImg.naturalHeight || displayHeight;
  
  templatePointsCanvas.width = naturalWidth;
  templatePointsCanvas.height = naturalHeight;
  templatePointsCanvas.style.width = displayWidth + 'px';
  templatePointsCanvas.style.height = displayHeight + 'px';
  // Also resize mask canvas to match natural dimensions
  templateMaskCanvas.width = naturalWidth;
  templateMaskCanvas.height = naturalHeight;
  templateMaskCanvas.style.width = displayWidth + 'px';
  templateMaskCanvas.style.height = displayHeight + 'px';
  
  // Align overlays with the actual rendered image inside the container
  const containerWidth = templatePreviewContainer.clientWidth;
  const containerHeight = templatePreviewContainer.clientHeight;
  const offsetX = Math.max(0, (containerWidth - displayWidth) / 2);
  const offsetY = Math.max(0, (containerHeight - displayHeight) / 2);
  templatePointsCanvas.style.left = offsetX + 'px';
  templatePointsCanvas.style.top = offsetY + 'px';
  templateMaskCanvas.style.left = offsetX + 'px';
  templateMaskCanvas.style.top = offsetY + 'px';
  
  // Redraw points if they exist
  if (datasetState.currentPoints.length > 0) {
    drawTemplatePoints();
  }
}

let currentMaskData = null;

window.addEventListener("resize", () => {
  if (!pointCaptureBlock.hidden) {
    resizeTemplateCanvas();
    drawTemplatePoints();
    // Redraw mask overlay if it exists
    if (currentMaskData) {
      drawMaskOverlay(currentMaskData);
    }
  }
});

function drawTemplatePoints() {
  const ctx = templatePointsCanvas.getContext("2d");
  ctx.clearRect(0, 0, templatePointsCanvas.width, templatePointsCanvas.height);
  if (!templateImg.naturalWidth) return;
  
  // Canvas is now sized to natural dimensions, so points are already in correct coordinates
  // We just need to scale the point radius for display
  const displayScale = templateImg.clientWidth / templateImg.naturalWidth;
  const pointRadius = 5 / displayScale; // Scale point size to be visible at any zoom level
  
  for (const p of datasetState.currentPoints) {
    ctx.beginPath();
    ctx.fillStyle = p.positive ? "#10b981" : "#ef4444";
    ctx.arc(p.x, p.y, pointRadius, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = "#000";
    ctx.lineWidth = 2 / displayScale;
    ctx.stroke();
  }
}

let previewDebounceTimeout = null;

function debouncedMaskPreview() {
  // Debounce mask preview by 800ms to avoid excessive API calls
  clearTimeout(previewDebounceTimeout);
  previewDebounceTimeout = setTimeout(() => {
    if (datasetState.currentPoints.length > 0) {
      templatePreviewBtn.click();
    }
  }, 800);
}

function addTemplatePoint(x, y, positive) {
  datasetState.currentPoints.push({ x, y, positive });
  drawTemplatePoints();
  clearMaskOverlay(); // Clear previous mask when adding new point
  templateSaveBtn.disabled = datasetState.currentPoints.length === 0;
  templateClearBtn.disabled = datasetState.currentPoints.length === 0;
  templatePreviewBtn.disabled = datasetState.currentPoints.length === 0;
  const pos = datasetState.currentPoints.filter(p => p.positive).length;
  const neg = datasetState.currentPoints.length - pos;
  pointCount.textContent = `${pos}+ / ${neg}-`;
  
  // Trigger debounced preview
  debouncedMaskPreview();
}

templateImg.addEventListener("contextmenu", e => e.preventDefault());
templateImg.addEventListener("click", e => handleTemplateClick(e, true));
templateImg.addEventListener("mousedown", e => {
  if (e.button === 2) handleTemplateClick(e, false);
});

function handleTemplateClick(e, positive) {
  if (!datasetState.currentReferenceFile) return;
  const rect = templateImg.getBoundingClientRect();
  const x = (e.clientX - rect.left) * (templateImg.naturalWidth / rect.width);
  const y = (e.clientY - rect.top) * (templateImg.naturalHeight / rect.height);
  addTemplatePoint(Math.round(x), Math.round(y), positive && !e.shiftKey);
}

templateClearBtn.addEventListener("click", () => {
  datasetState.currentPoints = [];
  drawTemplatePoints();
  clearMaskOverlay();
  templateSaveBtn.disabled = true;
  templateClearBtn.disabled = true;
  templatePreviewBtn.disabled = true;
  pointCount.textContent = "";
});

// Preview SAM mask
templatePreviewBtn.addEventListener("click", async () => {
  if (!datasetState.currentPoints.length) return;
  templateStatus.textContent = "Generating mask preview...";
  templatePreviewBtn.disabled = true;
  const w = templateImg.naturalWidth;
  const h = templateImg.naturalHeight;
  const normalizedPoints = datasetState.currentPoints.map(p => ({
    x_norm: w > 1 ? p.x / (w - 1) : 0,
    y_norm: h > 1 ? p.y / (h - 1) : 0,
    positive: p.positive
  }));
  try {
    const resp = await fetch("/api/sam/dataset/point_preview", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        dataset_id: datasetState.datasetId,
        image_id: datasetState.currentReferenceId,
        points: normalizedPoints
      })
    });
    const data = await resp.json();
    if (!resp.ok) {
      templateStatus.textContent = data.error || "Preview failed";
      templatePreviewBtn.disabled = false;
      return;
    }
    // Draw mask overlay and store for resize events
    currentMaskData = data.mask_png;
    drawMaskOverlay(currentMaskData);
    templateStatus.textContent = `Mask preview (score: ${data.score.toFixed(2)})`;
    templatePreviewBtn.disabled = false;
  } catch (e) {
    console.error(e);
    templateStatus.textContent = "Preview error";
    templatePreviewBtn.disabled = false;
  }
});

function drawMaskOverlay(maskPngBase64) {
  const img = new Image();
  img.onload = () => {
    const ctx = templateMaskCanvas.getContext("2d");
    ctx.clearRect(0, 0, templateMaskCanvas.width, templateMaskCanvas.height);
    
    // Create temporary canvas to process mask
    const tempCanvas = document.createElement('canvas');
    tempCanvas.width = templateMaskCanvas.width;
    tempCanvas.height = templateMaskCanvas.height;
    const tempCtx = tempCanvas.getContext('2d');
    
    // Draw grayscale mask to temp canvas
    tempCtx.drawImage(img, 0, 0, tempCanvas.width, tempCanvas.height);
    
    // Get pixel data
    const imageData = tempCtx.getImageData(0, 0, tempCanvas.width, tempCanvas.height);
    const data = imageData.data;
    
    // Convert grayscale to green overlay (only where mask is white/bright)
    for (let i = 0; i < data.length; i += 4) {
      const brightness = data[i]; // Grayscale value (0=black, 255=white)
      if (brightness > 128) { // If pixel is part of mask (bright)
        data[i] = 16;      // R (green color #10b981)
        data[i + 1] = 185; // G
        data[i + 2] = 129; // B
        data[i + 3] = brightness * 0.5; // Alpha (semi-transparent)
      } else {
        data[i + 3] = 0; // Fully transparent (no mask here)
      }
    }
    
    // Draw processed overlay
    ctx.putImageData(imageData, 0, 0);
  };
  img.src = "data:image/png;base64," + maskPngBase64;
}

templateSaveBtn.addEventListener("click", async () => {
  if (!datasetState.currentPoints.length || !datasetState.currentReferenceFilename) return;
  templateStatus.textContent = "Saving template...";
  templateSaveBtn.disabled = true;
  const w = templateImg.naturalWidth;
  const h = templateImg.naturalHeight;
  const normalizedPoints = datasetState.currentPoints.map(p => ({
    x_norm: w > 1 ? p.x / (w - 1) : 0,
    y_norm: h > 1 ? p.y / (h - 1) : 0,
    positive: p.positive
  }));
  const payload = {
    dataset_id: datasetState.datasetId,
    image_filename: datasetState.currentReferenceFilename,
    image_id: datasetState.currentReferenceId,
    points: normalizedPoints,
    name: templateName.value.trim() || undefined,
    class: templateClass.value || undefined
  };
  try {
    const resp = await fetch("/api/sam/dataset/template/save", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
    const data = await resp.json();
    if (!resp.ok) {
      templateStatus.textContent = data.error || "Save failed";
      templateSaveBtn.disabled = false;
      return;
    }
    templateStatus.textContent = "Template saved";
    datasetState.templates.push({
      template_id: data.template_id,
      name: data.name || `Template ${datasetState.templates.length + 1}`,
      class: data.class || '',
      image_filename: datasetState.currentReferenceFilename,
      points: normalizedPoints,
      edits: {}
    });
    renderTemplateList();
    datasetState.currentPoints = [];
    drawTemplatePoints();
    clearMaskOverlay();
    templateName.value = "";
    templateClass.value = "";
    templateSaveBtn.disabled = true;
    templateClearBtn.disabled = true;
    templatePreviewBtn.disabled = true;
    pointCount.textContent = "";
    pointCaptureBlock.hidden = true;
  // Remove active selection across both galleries
  [ ...(referenceGalleryFail?.children || []), ...(referenceGalleryPass?.children || []) ].forEach(c => c.classList.remove("active"));
  } catch (e) {
    console.error(e);
    templateStatus.textContent = "Error";
    templateSaveBtn.disabled = false;
  }
});

function clearMaskOverlay() {
  currentMaskData = null;
  const ctx = templateMaskCanvas.getContext("2d");
  ctx.clearRect(0, 0, templateMaskCanvas.width, templateMaskCanvas.height);
}

function renderTemplateList() {
  templateList.innerHTML = "";
  if (!datasetState.templates.length) {
    templateList.innerHTML = '<div class="hint">No templates yet. Click a reference image to create one.</div>';
    proceedToEditsBtn.disabled = true;
    return;
  }
  datasetState.templates.forEach((t, idx) => {
    const card = document.createElement("div");
    card.className = "template-card";
    const classLabel = t.class ? ` [${t.class}]` : '';
    card.innerHTML = `
      <strong>${t.name}${classLabel}</strong>
      <span class="template-meta">${t.image_filename} · ${t.points.length} pt(s)</span>
    `;
    templateList.appendChild(card);
  });
  proceedToEditsBtn.disabled = false;
}

proceedToEditsBtn.addEventListener("click", () => {
  showStep(stepGenerate);
  renderTemplateEdits();
  templatePreviewSection.hidden = false; // Show preview section
});

// Template preview before generation
previewTemplateBtn.addEventListener("click", async () => {
  const classFilter = previewClassFilter.value;
  previewStatus.textContent = "Generating preview...";
  previewTemplateBtn.disabled = true;
  
  // Find first matching image based on class filter
  let targetImage = null;
  if (classFilter) {
    targetImage = datasetState.images.find(img => 
      img.filename.toLowerCase().includes(classFilter)
    );
    if (!targetImage) {
      previewStatus.textContent = `No ${classFilter} images found in dataset`;
      previewTemplateBtn.disabled = false;
      return;
    }
  } else {
    targetImage = datasetState.images[0];
  }
  
  const edits = {};
  datasetState.templates.forEach(t => {
    edits[t.template_id] = t.edits || {};
  });
  
  try {
    const resp = await fetch("/api/sam/dataset/template/preview", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        dataset_id: datasetState.datasetId,
        edits,
        image_id: targetImage.id,
        class_filter: classFilter,
        backlight_simulation: backlightToggle && backlightToggle.checked ? true : undefined
      })
    });
    const data = await resp.json();
    if (!resp.ok) {
      previewStatus.textContent = data.error || "Preview failed";
      previewTemplateBtn.disabled = false;
      return;
    }
    previewResultImg.src = "data:image/png;base64," + data.variant_png;
    previewResultImg.style.display = "block";
    previewPlaceholder.style.display = "none";
    const classLabel = classFilter ? ` [${classFilter}]` : '';
    previewStatus.textContent = `Preview${classLabel}: ${data.filename}`;
    previewTemplateBtn.disabled = false;
  } catch (e) {
    console.error(e);
    previewStatus.textContent = "Error: " + (e.message || "Unknown");
    previewTemplateBtn.disabled = false;
  }
});

// When the preview class filter changes, re-render the template edits list
if (previewClassFilter) {
  previewClassFilter.addEventListener('change', () => {
    if (isElementInStep(stepGenerate)) {
      renderTemplateEdits();
    }
  });
}

// Step 3: Edit Configuration & Generation
function renderTemplateEdits() {
  templateEditsList.innerHTML = "";
  const activeClass = previewClassFilter ? previewClassFilter.value : "";
  datasetState.templates.forEach((template, idx) => {
    // If a class filter is active, only show templates whose class matches (or hide if mismatch)
    if (activeClass && template.class !== activeClass) return;
    const block = document.createElement("div");
    block.className = "template-edit-block";
    const header = document.createElement("h4");
    header.textContent = template.name;
    block.appendChild(header);
    const editsGrid = document.createElement("div");
    editsGrid.className = "edits-grid";
    editsGrid.dataset.templateIdx = idx;
    const fields = [
      { key: "brightness", label: "Darker ←→ Lighter", min: -1, max: 1, step: 0.02, def: 0, 
        tooltip: "Adjusts overall brightness. Negative values make darker (shadows), positive values make lighter (highlights). Range: -1 to +1" },
      { key: "contrast", label: "Flatter ←→ Punchier", min: -1, max: 1, step: 0.02, def: 0,
        tooltip: "Controls difference between light and dark areas. Negative reduces contrast (flatter), positive increases contrast (punchier). Range: -1 to +1" },
      { key: "gamma", label: "Lift Shadows ←→ Deepen", min: -0.9, max: 2, step: 0.05, def: 0,
        tooltip: "Non-linear brightness adjustment. Negative lifts shadows (brightens dark areas), positive deepens shadows (darkens dark areas while keeping highlights). Range: -0.9 to +2" },
      { key: "hue", label: "Hue Rotate", min: -180, max: 180, step: 1, def: 0,
        tooltip: "Rotates colors on color wheel. 0=original, ±60=subtle shift, ±120=complementary colors, ±180=opposite colors. Range: -180° to +180°" },
      { key: "saturation", label: "Muted ←→ Vivid", min: -1, max: 3, step: 0.05, def: 0,
        tooltip: "Controls color intensity. Negative desaturates (grayscale), 0=original, positive intensifies colors (more vivid). Range: -1 to +3" },
      { key: "sharpen", label: "Softer ←→ Sharper", min: 0, max: 2, step: 0.1, def: 0,
        tooltip: "Enhances edge definition. 0=no sharpening, 1=moderate sharpening, 2=maximum sharpening (may create artifacts). Range: 0 to 2" },
      { key: "noise", label: "Clean ←→ Texture", min: 0, max: 0.2, step: 0.01, def: 0,
        tooltip: "Adds grain/texture. 0=clean, 0.05=subtle texture, 0.1=moderate grain, 0.2=heavy texture. Useful for matching photo grain. Range: 0 to 0.2" },
      { key: "opacity", label: "Transparent ←→ Solid", min: 0, max: 1, step: 0.02, def: 1,
        tooltip: "Blends edited region with original. 0=fully transparent (original shows), 0.5=50% blend, 1=fully opaque (only edited shows). Range: 0 to 1" }
    ];
    fields.forEach(f => {
      const val = template.edits[f.key] !== undefined ? template.edits[f.key] : f.def;
      const wrap = document.createElement("label");
      wrap.title = f.tooltip; // Add native browser tooltip
      wrap.className = "edit-field-label";
      wrap.innerHTML = `<span class="edit-label-text" data-tooltip="${f.tooltip}">${f.label} <span class="tooltip-icon">?</span></span><input type="range" data-field="${f.key}" value="${val}" min="${f.min}" max="${f.max}" step="${f.step}" /><input type="number" data-sync-field="${f.key}" value="${val}" min="${f.min}" max="${f.max}" step="${f.step}" />`;
      editsGrid.appendChild(wrap);
    });
    block.appendChild(editsGrid);
    templateEditsList.appendChild(block);
  });
  generateBtn.disabled = false;
}

templateEditsList.addEventListener("input", e => {
  const t = e.target;
  const grid = t.closest(".edits-grid");
  if (!grid) return;
  const idx = parseInt(grid.dataset.templateIdx, 10);
  if (t.matches("input[data-field]")) {
    const field = t.dataset.field;
    const num = grid.querySelector(`input[data-sync-field="${field}"]`);
    if (num) num.value = t.value;
    datasetState.templates[idx].edits[field] = parseFloat(t.value);
  } else if (t.matches("input[data-sync-field]")) {
    const field = t.dataset.syncField;
    const range = grid.querySelector(`input[data-field="${field}"]`);
    if (range) range.value = t.value;
    datasetState.templates[idx].edits[field] = parseFloat(t.value);
  }
});

generateBtn.addEventListener("click", async () => {
  generateBtn.disabled = true;
  generateStatus.textContent = "Starting generation...";
  generateResults.innerHTML = "<div style='text-align:center; padding:2rem; color:#8ea1af; font-size:0.65rem;'>Generating... Results will download automatically. Check status above.</div>";
  datasetState.results = [];
  
  // Show modal ONLY when button is clicked
  showGenerationModal();
  updateModalStatus("Segmenting and applying edits...", "This may take a few moments");
  
  const edits = {};
  datasetState.templates.forEach(t => {
    edits[t.template_id] = t.edits || {};
  });
  const payload = {
    dataset_id: datasetState.datasetId,
    edits,
    backlight_simulation: backlightToggle && backlightToggle.checked ? true : undefined
  };
  try {
    const resp = await fetch("/api/sam/dataset/apply_stream", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
    if (!resp.ok) {
      const err = await resp.json();
      generateStatus.textContent = err.error || "Generation failed";
      updateModalStatus("Error", err.error || "Generation failed");
      modalCancelBtn.textContent = "Close";
      generateBtn.disabled = false;
      return;
    }
    const reader = resp.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let processedCount = 0;
    while (true) {
      if (isGenerationCancelled) {
        reader.cancel();
        generateStatus.textContent = "Generation cancelled";
        hideGenerationModal();
        generateBtn.disabled = false;
        return;
      }
      
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      const parts = buffer.split(/\n\n/);
      buffer = parts.pop() || "";
      for (const chunk of parts) {
        const line = chunk.trim();
        if (!line.startsWith("data:")) continue;
        const payloadStr = line.slice(5).trim();
        if (payloadStr === "[DONE]" || payloadStr.includes('"done":true')) {
          generateStatus.textContent = `Complete! Downloaded ${datasetState.results.length} images`;
          setModalComplete();
          await downloadAllResults();
          generateBtn.disabled = false;
          // Auto-hide modal after 3 seconds
          setTimeout(() => hideGenerationModal(), 3000);
          return;
        }
        try {
          const obj = JSON.parse(payloadStr);
          if (obj.variant_png) {
            datasetState.results.push(obj);
            processedCount++;
            generateStatus.textContent = `Generating... ${processedCount} / ${datasetState.images.length} images`;
            updateModalProgress(processedCount, datasetState.images.length);
            if (obj.filename) {
              currentImageName.textContent = obj.filename;
            }
          }
        } catch (e) {
          /* ignore partial JSON */
        }
      }
    }
    generateStatus.textContent = `Complete! Downloaded ${datasetState.results.length} images`;
    setModalComplete();
    await downloadAllResults();
    generateBtn.disabled = false;
    // Auto-hide modal after 3 seconds
    setTimeout(() => hideGenerationModal(), 3000);
  } catch (e) {
    console.error(e);
    generateStatus.textContent = "Error: " + (e.message || "Unknown");
    updateModalStatus("Error", e.message || "Unknown error occurred");
    modalCancelBtn.textContent = "Close";
    generateBtn.disabled = false;
  }
});

// Auto-download results as they're generated
async function downloadAllResults() {
  if (!datasetState.results.length) return;
  generateStatus.textContent = "Creating ZIP...";
  const zip = new JSZip();
  const folder = zip.folder("variants");
  datasetState.results.forEach((res, idx) => {
    const imgData = res.variant_png;
    folder.file(res.filename || `variant_${idx}.png`, imgData, { base64: true });
  });
  const blob = await zip.generateAsync({ type: "blob" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `dataset_${datasetState.datasetId.substring(0, 8)}_variants.zip`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
  generateStatus.textContent = `Downloaded ${datasetState.results.length} images as ZIP`;
}

// downloadAllBtn no longer needed - auto-download on generate complete

downloadAllBtn.addEventListener("click", async () => {
  if (!datasetState.results.length) return;
  downloadAllBtn.disabled = true;
  generateStatus.textContent = "Creating ZIP...";
  try {
    const zip = new JSZip();
    for (const r of datasetState.results) {
      const base64 = r.variant_png;
      const binary = atob(base64);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) {
        bytes[i] = binary.charCodeAt(i);
      }
      zip.file(r.filename.replace(/\.(jpg|jpeg|png)$/i, "_variant.png"), bytes);
    }
    const blob = await zip.generateAsync({ type: "blob" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `dataset_${datasetState.datasetId}_variants.zip`;
    a.click();
    URL.revokeObjectURL(url);
    generateStatus.textContent = "ZIP downloaded";
  } catch (e) {
    console.error(e);
    generateStatus.textContent = "ZIP error";
  }
  downloadAllBtn.disabled = false;
});

backToTemplates.addEventListener("click", () => {
  showStep(stepTemplate);
});

// Tooltip system for edit parameters
let activeTooltip = null;

function showCustomTooltip(element, text) {
  hideCustomTooltip();
  const tooltip = document.createElement('div');
  tooltip.className = 'custom-tooltip show';
  tooltip.textContent = text;
  element.style.position = 'relative';
  element.appendChild(tooltip);
  activeTooltip = tooltip;
}

function hideCustomTooltip() {
  if (activeTooltip) {
    activeTooltip.remove();
    activeTooltip = null;
  }
}

// Add hover listeners for tooltips
document.addEventListener('mouseover', (e) => {
  const labelText = e.target.closest('.edit-label-text');
  if (labelText) {
    const tooltipText = labelText.dataset.tooltip;
    if (tooltipText) {
      showCustomTooltip(labelText, tooltipText);
    }
  }
});

document.addEventListener('mouseout', (e) => {
  const labelText = e.target.closest('.edit-label-text');
  if (labelText) {
    hideCustomTooltip();
  }
});

// Request notification permission
if ("Notification" in window && Notification.permission === "default") {
  Notification.requestPermission();
}

showStep(stepDataset);
