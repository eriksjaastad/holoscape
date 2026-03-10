# Phase 1B Week 3: Window Polish + Visualizer Enhancement

**Goal:** Polish the Electron window with macOS integration and enhance the visualizer with GPU-based animation.

## Current State (from Spikes + Phase 1A)
- ✅ Frameless, transparent window with vibrancy (Spike 1)
- ✅ Custom drag handle (Spike 3)  
- ✅ Three.js particle sphere breathing animation (Spike 1)
- ✅ Basic visualizer states: idle, thinking, speaking (Spike 2)
- ✅ TypeScript + service architecture (Phase 1A)
- ✅ 120fps achieved (exceeds 60fps target)

## What You're Building
1. macOS menu bar integration
2. Global hotkey (Cmd+Shift+H to show/hide)
3. GPU-based vertex shader for breathing animation
4. Expanded visualizer states with smooth transitions
5. Tray icon (optional, for quick access)

---

## Step 1: macOS Menu Bar Integration

Create `src/main/menu.ts`:

```typescript
import { Menu, app, shell } from 'electron';
import type { MenuItemConstructorOptions } from 'electron';
import { createLogger } from './services/logger';

const log = createLogger('Menu');

export function createAppMenu(): Menu {
  const template: MenuItemConstructorOptions[] = [
    {
      label: app.name,
      submenu: [
        { role: 'about' },
        { type: 'separator' },
        {
          label: 'Preferences...',
          accelerator: 'Cmd+,',
          click: () => {
            log.info('Preferences clicked');
            // TODO: Open preferences window
          },
        },
        { type: 'separator' },
        { role: 'services' },
        { type: 'separator' },
        { role: 'hide' },
        { role: 'hideOthers' },
        { role: 'unhide' },
        { type: 'separator' },
        { role: 'quit' },
      ],
    },
    {
      label: 'Edit',
      submenu: [
        { role: 'undo' },
        { role: 'redo' },
        { type: 'separator' },
        { role: 'cut' },
        { role: 'copy' },
        { role: 'paste' },
        { role: 'selectAll' },
      ],
    },
    {
      label: 'View',
      submenu: [
        { role: 'reload' },
        { role: 'forceReload' },
        { role: 'toggleDevTools' },
        { type: 'separator' },
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
        { type: 'separator' },
        { role: 'togglefullscreen' },
      ],
    },
    {
      label: 'Window',
      submenu: [
        { role: 'minimize' },
        { role: 'zoom' },
        { type: 'separator' },
        {
          label: 'Show/Hide Hologram',
          accelerator: 'Cmd+Shift+H',
          click: (_menuItem, browserWindow) => {
            if (browserWindow) {
              if (browserWindow.isVisible()) {
                browserWindow.hide();
              } else {
                browserWindow.show();
                browserWindow.focus();
              }
            }
          },
        },
        { type: 'separator' },
        { role: 'front' },
      ],
    },
    {
      label: 'Help',
      submenu: [
        {
          label: 'Learn More',
          click: () => {
            shell.openExternal('https://github.com/eriksjaastad/hologram');
          },
        },
      ],
    },
  ];

  return Menu.buildFromTemplate(template);
}
```

Update `src/main/index.ts` to use the menu:

```typescript
// Add import at top
import { Menu } from 'electron';
import { createAppMenu } from './menu';

// In app.whenReady(), after createWindow():
Menu.setApplicationMenu(createAppMenu());
```

---

## Step 2: Global Hotkey

Install the dependency:
```bash
npm install electron-globalShortcut
```

Note: `globalShortcut` is built into Electron, no install needed. Create `src/main/shortcuts.ts`:

```typescript
import { globalShortcut, BrowserWindow } from 'electron';
import { createLogger } from './services/logger';

const log = createLogger('Shortcuts');

const SHORTCUTS = {
  toggleWindow: 'CommandOrControl+Shift+H',
} as const;

export function registerGlobalShortcuts(getWindow: () => BrowserWindow | null): void {
  // Toggle window visibility
  const registered = globalShortcut.register(SHORTCUTS.toggleWindow, () => {
    const window = getWindow();
    if (!window) {
      log.warn('No window to toggle');
      return;
    }

    if (window.isVisible()) {
      log.debug('Hiding window via hotkey');
      window.hide();
    } else {
      log.debug('Showing window via hotkey');
      window.show();
      window.focus();
    }
  });

  if (registered) {
    log.info('Global shortcuts registered', { shortcuts: Object.values(SHORTCUTS) });
  } else {
    log.error('Failed to register global shortcuts');
  }
}

export function unregisterGlobalShortcuts(): void {
  globalShortcut.unregisterAll();
  log.info('Global shortcuts unregistered');
}
```

Update `src/main/index.ts`:

```typescript
// Add import
import { registerGlobalShortcuts, unregisterGlobalShortcuts } from './shortcuts';

// After createWindow() in whenReady:
registerGlobalShortcuts(() => mainWindow);

// In before-quit handler:
app.on('before-quit', async () => {
  log.info('App shutting down');
  unregisterGlobalShortcuts();
  await registry.shutdownAll();
});

// Also unregister on will-quit (belt and suspenders)
app.on('will-quit', () => {
  unregisterGlobalShortcuts();
});
```

---

## Step 3: GPU-Based Vertex Shader

Replace the CPU-based breathing animation with a GPU shader. Update `src/renderer/visualizer.ts`:

```typescript
import * as THREE from 'three';
import type { VisualizerState, ProcessMetrics } from '@shared/types';

// ... keep existing DOM element references ...

// Shader for GPU-based breathing animation
const vertexShader = `
  uniform float uTime;
  uniform float uBreathSpeed;
  uniform float uBreathScale;
  
  varying vec3 vPosition;
  
  void main() {
    vPosition = position;
    
    // Breathing effect calculated on GPU
    float breath = sin(uTime * uBreathSpeed) * uBreathScale + 1.0;
    vec3 newPosition = position * breath;
    
    // Add subtle per-particle jitter for organic feel
    float jitter = sin(position.x * 10.0 + uTime * 0.5) * 0.02;
    newPosition += normal * jitter;
    
    gl_Position = projectionMatrix * modelViewMatrix * vec4(newPosition, 1.0);
    gl_PointSize = 3.5;
  }
`;

const fragmentShader = `
  uniform vec3 uColor;
  uniform float uOpacity;
  
  varying vec3 vPosition;
  
  void main() {
    // Soft circular point
    vec2 center = gl_PointCoord - vec2(0.5);
    float dist = length(center);
    if (dist > 0.5) discard;
    
    float alpha = smoothstep(0.5, 0.2, dist) * uOpacity;
    gl_FragColor = vec4(uColor, alpha);
  }
`;

// Create shader material
const shaderMaterial = new THREE.ShaderMaterial({
  vertexShader,
  fragmentShader,
  uniforms: {
    uTime: { value: 0 },
    uBreathSpeed: { value: 0.0013 },
    uBreathScale: { value: 0.05 },
    uColor: { value: new THREE.Color(0x7efbff) },
    uOpacity: { value: 0.9 },
  },
  transparent: true,
  blending: THREE.AdditiveBlending,
  depthWrite: false,
});

// Visualizer state configurations with transition targets
interface StateConfig {
  color: THREE.Color;
  breathSpeed: number;
  breathScale: number;
  transitionDuration: number; // ms
}

const stateConfigs: Record<VisualizerState, StateConfig> = {
  idle: {
    color: new THREE.Color(0x7efbff),
    breathSpeed: 0.0013,
    breathScale: 0.05,
    transitionDuration: 800,
  },
  thinking: {
    color: new THREE.Color(0xca79ff),
    breathSpeed: 0.0031,
    breathScale: 0.07,
    transitionDuration: 300,
  },
  speaking: {
    color: new THREE.Color(0x4dfdd1),
    breathSpeed: 0.0045,
    breathScale: 0.09,
    transitionDuration: 200,
  },
  listening: {
    color: new THREE.Color(0xffcc66),
    breathSpeed: 0.002,
    breathScale: 0.06,
    transitionDuration: 400,
  },
  error: {
    color: new THREE.Color(0xff6666),
    breathSpeed: 0.006,
    breathScale: 0.03,
    transitionDuration: 150,
  },
};

// Transition state
let currentState: VisualizerState = 'idle';
let targetConfig = stateConfigs.idle;
let transitionStart = 0;
let transitionFrom: StateConfig = stateConfigs.idle;
let isTransitioning = false;

// Easing function
function easeOutCubic(t: number): number {
  return 1 - Math.pow(1 - t, 3);
}

// Interpolate between configs
function lerpConfig(from: StateConfig, to: StateConfig, t: number): void {
  const eased = easeOutCubic(t);
  
  // Interpolate color
  const currentColor = new THREE.Color().lerpColors(from.color, to.color, eased);
  shaderMaterial.uniforms.uColor.value = currentColor;
  
  // Interpolate breath parameters
  shaderMaterial.uniforms.uBreathSpeed.value = 
    from.breathSpeed + (to.breathSpeed - from.breathSpeed) * eased;
  shaderMaterial.uniforms.uBreathScale.value = 
    from.breathScale + (to.breathScale - from.breathScale) * eased;
}

export function setVisualizerState(state: VisualizerState): void {
  if (state === currentState) return;
  
  // Start transition
  transitionFrom = {
    color: shaderMaterial.uniforms.uColor.value.clone(),
    breathSpeed: shaderMaterial.uniforms.uBreathSpeed.value,
    breathScale: shaderMaterial.uniforms.uBreathScale.value,
    transitionDuration: 0,
  };
  targetConfig = stateConfigs[state] ?? stateConfigs.idle;
  transitionStart = performance.now();
  isTransitioning = true;
  currentState = state;
}

window.setVisualizerState = setVisualizerState;

// ... keep scene, camera, renderer setup but replace material usage ...

// Replace the Points with shader material
const geometry = new THREE.IcosahedronGeometry(1.4, 5); // Higher detail
const particles = new THREE.Points(geometry, shaderMaterial);
scene.add(particles);

// Inner sphere with same shader but different base values
const innerMaterial = shaderMaterial.clone();
innerMaterial.uniforms.uColor.value = new THREE.Color(0xff99ff);
innerMaterial.uniforms.uOpacity.value = 0.65;
const innerSphere = new THREE.Points(
  new THREE.IcosahedronGeometry(1.0, 4),
  innerMaterial
);
scene.add(innerSphere);

// Update animate function
function animate(timestamp: number): void {
  requestAnimationFrame(animate);

  // Update shader time
  shaderMaterial.uniforms.uTime.value = timestamp * 0.001;
  innerMaterial.uniforms.uTime.value = timestamp * 0.001;

  // Handle state transitions
  if (isTransitioning) {
    const elapsed = timestamp - transitionStart;
    const progress = Math.min(elapsed / targetConfig.transitionDuration, 1);
    
    lerpConfig(transitionFrom, targetConfig, progress);
    
    // Also update inner sphere
    innerMaterial.uniforms.uBreathSpeed.value = shaderMaterial.uniforms.uBreathSpeed.value * 0.8;
    innerMaterial.uniforms.uBreathScale.value = shaderMaterial.uniforms.uBreathScale.value * 0.7;
    
    if (progress >= 1) {
      isTransitioning = false;
    }
  }

  // Rotation (still on CPU, very cheap)
  particles.rotation.y += 0.0012;
  particles.rotation.z += 0.0006;
  innerSphere.rotation.y -= 0.0015;
  innerSphere.rotation.x += 0.0005;

  // FPS tracking
  const elapsed = timestamp - lastMetricUpdate;
  fpsFrameCount += 1;
  if (elapsed >= 500) {
    const fps = (fpsFrameCount / elapsed) * 1000;
    updateFpsDisplay(fps);
    fpsFrameCount = 0;
    lastMetricUpdate = timestamp;
  }

  renderer.render(scene, camera);
}

requestAnimationFrame(animate);
```

---

## Step 4: Update Shared Types for New States

The `VisualizerState` type in `src/shared/ipc-types.ts` already includes `'listening'` and `'error'`. Verify it matches:

```typescript
export type VisualizerState = 'idle' | 'thinking' | 'speaking' | 'listening' | 'error';
```

---

## Step 5: Add Window State IPC (for renderer to request show/hide)

Add to `src/shared/ipc-types.ts`:

```typescript
// In IPCInvokeChannels, add:
'window:toggle': {
  request: void;
  response: { visible: boolean };
};
'window:set-always-on-top': {
  request: { enabled: boolean };
  response: void;
};
```

Add handlers in `src/main/index.ts`:

```typescript
ipcMain.handle('window:toggle', () => {
  if (!mainWindow) return { visible: false };
  
  if (mainWindow.isVisible()) {
    mainWindow.hide();
    return { visible: false };
  } else {
    mainWindow.show();
    mainWindow.focus();
    return { visible: true };
  }
});

ipcMain.handle('window:set-always-on-top', (_event, { enabled }: { enabled: boolean }) => {
  if (mainWindow) {
    mainWindow.setAlwaysOnTop(enabled);
    log.info('Always on top changed', { enabled });
  }
});
```

---

## Step 6: Create Window Service

Create `src/main/services/window.ts`:

```typescript
import { BrowserWindow } from 'electron';
import type { Service } from './index';
import { createLogger } from './logger';

const log = createLogger('WindowService');

export class WindowService implements Service {
  name = 'window';
  private window: BrowserWindow | null = null;

  setWindow(window: BrowserWindow): void {
    this.window = window;
    
    // Track window events
    window.on('show', () => log.debug('Window shown'));
    window.on('hide', () => log.debug('Window hidden'));
    window.on('focus', () => log.debug('Window focused'));
    window.on('blur', () => log.debug('Window blurred'));
  }

  getWindow(): BrowserWindow | null {
    return this.window;
  }

  toggle(): boolean {
    if (!this.window) return false;
    
    if (this.window.isVisible()) {
      this.window.hide();
      return false;
    } else {
      this.window.show();
      this.window.focus();
      return true;
    }
  }

  async initialize(): Promise<void> {
    log.info('Window service initialized');
  }

  async shutdown(): Promise<void> {
    this.window = null;
  }
}
```

Register it in `src/main/index.ts`:

```typescript
import { WindowService } from './services/window';

const windowService = new WindowService();
registry.register(windowService);

// After creating window:
windowService.setWindow(mainWindow);

// Update shortcuts to use service:
registerGlobalShortcuts(() => windowService.getWindow());
```

---

## Verification Steps

1. `npm run typecheck` — No errors
2. `npm run lint` — Passes
3. `npm run build` — All bundles created
4. `npm run dev` — Test the following:
   - [ ] App menu appears in macOS menu bar
   - [ ] Cmd+Shift+H toggles window visibility (works from any app)
   - [ ] Visualizer has smooth color transitions between states
   - [ ] Breathing animation is smooth (GPU-based)
   - [ ] States: idle (cyan), thinking (purple), speaking (green), listening (orange), error (red)
   - [ ] FPS still 60+ (should be even better with GPU shader)

---

## Files Created
- `src/main/menu.ts`
- `src/main/shortcuts.ts`
- `src/main/services/window.ts`

## Files Modified
- `src/main/index.ts` — Menu, shortcuts, window service integration
- `src/renderer/visualizer.ts` — GPU shader + smooth transitions
- `src/shared/ipc-types.ts` — Window toggle channels

---

## 🛑 IF YOU GET STUCK — STOP AND ASK

**Do NOT guess if you encounter:**

1. **Shader compilation errors** — GLSL syntax is tricky
   - Document the exact error from DevTools console

2. **globalShortcut not working** — May need app permissions on macOS
   - Check System Preferences → Security & Privacy → Accessibility

3. **Menu not appearing** — Electron menu quirks
   - Verify Menu.setApplicationMenu() is called after app.whenReady()

4. **Transition glitches** — Color interpolation issues
   - Document what the visual artifact looks like

### Format for questions:
```
## BLOCKED: [Brief description]

**Step I'm on:** [Step number and name]

**What I was trying to do:**
[Description]

**What went wrong:**
[Error message or confusion]

**What I've tried:**
[List of attempts]

**My question:**
[Specific question for Opus]
```

## Related Documentation

- [[trading_strategy_framework]] - trading strategy
- [AI Model Cost Comparison](Documents/reference/MODEL_COST_COMPARISON.md) - AI models
- [Safety Systems](patterns/safety-systems.md) - security
