# Pre-warm Loading Wheel with Time Estimation

## Overview
Added a visual loading indicator with estimated time remaining for the cache pre-warming process during dataset initialization.

## Changes Made

### 1. HTML (`server/public/index.html`)
Added a status section with spinner between the dataset controls and preview:

```html
<div id="prewarmProgress" class="status-section" style="display:none;">
  <div class="status-icon">
    <svg class="spinner" viewBox="0 0 50 50">
      <circle class="path" cx="25" cy="25" r="20" fill="none" stroke-width="4"></circle>
    </svg>
  </div>
  <div class="status-text">
    <div class="status-title" id="prewarmTitle">Pre-warming cache...</div>
    <div class="status-subtitle" id="prewarmSubtitle">Estimated time: calculating...</div>
  </div>
</div>
```

**Features:**
- Animated spinning wheel (uses existing CSS spinner styles)
- Title showing progress (e.g., "Pre-warming cache... 15/50")
- Subtitle with time estimate and average speed

### 2. JavaScript (`server/public/script.js`)
Enhanced the prewarm progress tracking with:

**Time Estimation Algorithm:**
```javascript
const elapsed = Date.now() - startTime;
avgTimePerImage = elapsed / completed;
const remaining = total - completed;
const estimatedMs = remaining * avgTimePerImage;
```

**Display Format:**
- Under 1 minute: "45s"
- Over 1 minute: "5m 30s"
- Shows average time per image: "avg 18.5s per image"

**Progress Updates:**
- Shows current progress: "Pre-warming cache... 15/50"
- Updates time estimate with each completed image
- Hides spinner when complete
- Shows final status: "Dataset ready (cache pre-warmed: 50 embeddings)"

## User Experience

### Before
```
Dataset status text: "Pre-warming cache... 15/50"
```

### After
```
┌─────────────────────────────────────────────────────┐
│  ◯ ← (spinning)   Pre-warming cache... 15/50       │
│                   Estimated time remaining: 5m 30s   │
│                   (avg 18.5s per image)             │
└─────────────────────────────────────────────────────┘
```

## Benefits

1. **Visual Feedback**: Animated spinner shows the process is active
2. **Progress Tracking**: Clear "X/Y" completion counter
3. **Time Estimation**: Users know how long to wait
4. **Performance Insight**: Shows average time per image (helps identify slow uploads)
5. **Professional UX**: Matches modern web application standards

## Example Output

**Initial State:**
```
Pre-warming cache (50 images)...
Estimated time: calculating...
```

**Mid-Process:**
```
Pre-warming cache... 25/50
Estimated time remaining: 7m 45s (avg 19.2s per image)
```

**Completion:**
```
Dataset ready (cache pre-warmed: 50 embeddings)
```

## Technical Notes

- Uses Server-Sent Events (SSE) for real-time progress updates
- Time estimation improves accuracy as more images are processed
- Handles edge cases (first image has no time estimate yet)
- Gracefully degrades if prewarm fails (hides spinner, shows status)
- Reuses existing CSS spinner styles from the codebase

## Performance Context

With the cache fix + prewarm feature:
- **First request (without prewarm)**: 18-20s per image
- **With prewarm**: All subsequent requests take 1-3s (10-15x speedup)
- **Typical prewarm time**: 5-10 minutes for 30-50 images
- **User perception**: Much better with visual progress indicator

## Next Steps

To deploy this change:
1. Rebuild Docker image: `docker build -t photosynth-full:prewarm-ui .`
2. Push to ECR and update ECS service
3. Test with a real dataset upload
4. Monitor user feedback on time estimates accuracy
