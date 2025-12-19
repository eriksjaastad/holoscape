# Phase 1A Week 1: Project Scaffold

**Goal:** Convert the JavaScript spike into a proper TypeScript project with build tooling, linting, and testing infrastructure.

## Current State
- Working Electron app in `src/` with JavaScript files
- `main.js`, `preload.js`, `renderer.js`, `index.html`, `styles.css`
- Three.js visualizer + OpenAI streaming working
- No TypeScript, no build system, no linting

## Target State
- TypeScript everywhere
- Vite for renderer bundling
- esbuild for main/preload bundling  
- ESLint + Prettier
- Vitest ready for unit tests
- All existing functionality preserved

---

## Step 1: Install Dependencies

```bash
npm install -D typescript @types/node @types/three
npm install -D vite @vitejs/plugin-react esbuild
npm install -D eslint @typescript-eslint/parser @typescript-eslint/eslint-plugin
npm install -D prettier eslint-config-prettier eslint-plugin-prettier
npm install -D vitest @vitest/ui
npm install -D husky lint-staged
npm install -D concurrently wait-on
```

---

## Step 2: Create Directory Structure

```
src/
├── main/
│   ├── index.ts          (main process entry)
│   └── ipc-handlers.ts   (IPC handlers extracted)
├── preload/
│   └── index.ts          (preload script)
├── renderer/
│   ├── index.html        (move from src/)
│   ├── main.ts           (renderer entry, was renderer.js)
│   ├── visualizer.ts     (Three.js code extracted)
│   ├── chat.ts           (chat UI code extracted)
│   └── styles.css        (move from src/)
├── shared/
│   └── types.ts          (shared TypeScript types)
└── api/
    └── openai-stream.ts  (move from src/api/, convert to TS)
```

---

## Step 3: TypeScript Configuration

Create `tsconfig.json` (base config):
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "baseUrl": ".",
    "paths": {
      "@main/*": ["src/main/*"],
      "@renderer/*": ["src/renderer/*"],
      "@shared/*": ["src/shared/*"],
      "@api/*": ["src/api/*"]
    }
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
```

Create `tsconfig.main.json`:
```json
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "module": "CommonJS",
    "outDir": "dist/main"
  },
  "include": ["src/main/**/*", "src/shared/**/*"]
}
```

Create `tsconfig.preload.json`:
```json
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "module": "CommonJS",
    "outDir": "dist/preload"
  },
  "include": ["src/preload/**/*", "src/shared/**/*"]
}
```

Create `tsconfig.renderer.json`:
```json
{
  "extends": "./tsconfig.json",
  "compilerOptions": {
    "module": "ESNext",
    "outDir": "dist/renderer",
    "lib": ["ES2022", "DOM", "DOM.Iterable"]
  },
  "include": ["src/renderer/**/*", "src/shared/**/*", "src/api/**/*"]
}
```

---

## Step 4: Vite Configuration

Create `vite.config.ts`:
```typescript
import { defineConfig } from 'vite';
import path from 'path';

export default defineConfig({
  root: 'src/renderer',
  base: './',
  build: {
    outDir: '../../dist/renderer',
    emptyOutDir: true,
  },
  resolve: {
    alias: {
      '@renderer': path.resolve(__dirname, 'src/renderer'),
      '@shared': path.resolve(__dirname, 'src/shared'),
      '@api': path.resolve(__dirname, 'src/api'),
    },
  },
  server: {
    port: 5173,
  },
});
```

---

## Step 5: ESLint Configuration

Create `.eslintrc.cjs`:
```javascript
module.exports = {
  root: true,
  env: {
    node: true,
    browser: true,
    es2022: true,
  },
  parser: '@typescript-eslint/parser',
  parserOptions: {
    ecmaVersion: 'latest',
    sourceType: 'module',
  },
  plugins: ['@typescript-eslint'],
  extends: [
    'eslint:recommended',
    'plugin:@typescript-eslint/recommended',
    'plugin:prettier/recommended',
  ],
  rules: {
    '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
    '@typescript-eslint/explicit-function-return-type': 'off',
    'no-console': ['warn', { allow: ['warn', 'error'] }],
  },
  ignorePatterns: ['dist', 'node_modules', '*.js'],
};
```

---

## Step 6: Prettier Configuration

Create `.prettierrc`:
```json
{
  "semi": true,
  "singleQuote": true,
  "tabWidth": 2,
  "trailingComma": "es5",
  "printWidth": 100
}
```

Create `.prettierignore`:
```
dist
node_modules
*.md
```

---

## Step 7: Update package.json Scripts

Replace the scripts section:
```json
{
  "scripts": {
    "dev": "concurrently \"npm run dev:vite\" \"npm run dev:electron\"",
    "dev:vite": "vite",
    "dev:electron": "wait-on http://localhost:5173 && NODE_ENV=development electron .",
    "build": "npm run build:main && npm run build:preload && npm run build:renderer",
    "build:main": "esbuild src/main/index.ts --bundle --platform=node --outfile=dist/main/index.js --external:electron",
    "build:preload": "esbuild src/preload/index.ts --bundle --platform=node --outfile=dist/preload/index.js --external:electron",
    "build:renderer": "vite build",
    "lint": "eslint src --ext .ts,.tsx",
    "lint:fix": "eslint src --ext .ts,.tsx --fix",
    "format": "prettier --write src/**/*.{ts,tsx,css,html}",
    "test": "vitest run",
    "test:watch": "vitest",
    "typecheck": "tsc --noEmit",
    "prepare": "husky install"
  },
  "main": "dist/main/index.js"
}
```

---

## Step 8: Convert Main Process

Create `src/main/index.ts`:
```typescript
import { app, BrowserWindow, ipcMain } from 'electron';
import path from 'path';
import 'dotenv/config';

let mainWindow: BrowserWindow | null = null;

// Metrics tracking
let lastCpuUsage = process.cpuUsage();
let lastCpuTime = process.hrtime.bigint();

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 960,
    height: 720,
    minWidth: 500,
    minHeight: 320,
    transparent: true,
    frame: false,
    vibrancy: 'ultra-dark',
    hasShadow: true,
    backgroundColor: '#00000000',
    webPreferences: {
      preload: path.join(__dirname, '../preload/index.js'),
      nodeIntegration: false,
      contextIsolation: true,
    },
  });

  // In dev, load from Vite server; in prod, load built files
  if (process.env.NODE_ENV === 'development') {
    mainWindow.loadURL('http://localhost:5173');
    mainWindow.webContents.openDevTools({ mode: 'detach' });
  } else {
    mainWindow.loadFile(path.join(__dirname, '../renderer/index.html'));
  }
}

// IPC Handlers
ipcMain.handle('get-api-key', () => process.env.OPENAI_API_KEY || null);

ipcMain.handle('get-process-metrics', () => {
  const now = process.hrtime.bigint();
  const intervalNs = Number(now - lastCpuTime);
  lastCpuTime = now;

  const cpuUsage = process.cpuUsage(lastCpuUsage);
  lastCpuUsage = process.cpuUsage();
  const memUsage = process.memoryUsage();

  const cpuMicroseconds = cpuUsage.user + cpuUsage.system;
  const intervalMs = intervalNs / 1_000_000;
  const cpuMs = cpuMicroseconds / 1000;
  const cpuPercent = intervalMs > 0 ? (cpuMs / intervalMs) * 100 : 0;

  return {
    cpuPercent,
    heapUsedMB: memUsage.heapUsed / 1024 / 1024,
    heapTotalMB: memUsage.heapTotal / 1024 / 1024,
    rssUsedMB: memUsage.rss / 1024 / 1024,
  };
});

// App lifecycle
app.whenReady().then(createWindow);

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
```

---

## Step 9: Convert Preload

Create `src/preload/index.ts`:
```typescript
import { contextBridge, ipcRenderer } from 'electron';

export interface HologramAPI {
  version: string;
  getMetrics: () => Promise<{
    cpuPercent: number;
    heapUsedMB: number;
    heapTotalMB: number;
    rssUsedMB: number;
  }>;
  getApiKey: () => Promise<string | null>;
}

const api: HologramAPI = {
  version: '0.1.0-alpha',
  getMetrics: () => ipcRenderer.invoke('get-process-metrics'),
  getApiKey: () => ipcRenderer.invoke('get-api-key'),
};

contextBridge.exposeInMainWorld('hologram', api);
```

---

## Step 10: Create Shared Types

Create `src/shared/types.ts`:
```typescript
// Visualizer states
export type VisualizerState = 'idle' | 'thinking' | 'speaking';

// IPC channel types
export interface IPCChannels {
  'get-api-key': () => Promise<string | null>;
  'get-process-metrics': () => Promise<ProcessMetrics>;
}

export interface ProcessMetrics {
  cpuPercent: number;
  heapUsedMB: number;
  heapTotalMB: number;
  rssUsedMB: number;
}

// Chat types
export interface ChatMessage {
  role: 'user' | 'assistant' | 'system';
  content: string;
}

// Extend Window for hologram API
declare global {
  interface Window {
    hologram: {
      version: string;
      getMetrics: () => Promise<ProcessMetrics>;
      getApiKey: () => Promise<string | null>;
    };
  }
}
```

---

## Step 11: Convert Renderer Files

Move and convert the existing renderer files to TypeScript:

1. Move `src/index.html` → `src/renderer/index.html`
2. Move `src/styles.css` → `src/renderer/styles.css`  
3. Convert `src/renderer.js` → `src/renderer/main.ts`
4. Convert `src/api/openai-stream.js` → `src/api/openai-stream.ts`

Update the HTML to reference the new entry point:
```html
<script type="module" src="./main.ts"></script>
```

Add proper TypeScript types to all converted files.

---

## Step 12: Vitest Configuration

Create `vitest.config.ts`:
```typescript
import { defineConfig } from 'vitest/config';
import path from 'path';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
  },
  resolve: {
    alias: {
      '@main': path.resolve(__dirname, 'src/main'),
      '@renderer': path.resolve(__dirname, 'src/renderer'),
      '@shared': path.resolve(__dirname, 'src/shared'),
      '@api': path.resolve(__dirname, 'src/api'),
    },
  },
});
```

Create a placeholder test `src/shared/types.test.ts`:
```typescript
import { describe, it, expect } from 'vitest';

describe('types', () => {
  it('should compile', () => {
    expect(true).toBe(true);
  });
});
```

---

## Step 13: Husky + Lint-Staged Setup

Run:
```bash
npx husky install
npx husky add .husky/pre-commit "npx lint-staged"
```

Add to `package.json`:
```json
{
  "lint-staged": {
    "*.{ts,tsx}": ["eslint --fix", "prettier --write"],
    "*.{css,html,json}": ["prettier --write"]
  }
}
```

---

## Verification Steps

After completing all steps, run:

1. `npm run typecheck` — Should pass with no errors
2. `npm run lint` — Should pass
3. `npm run test` — Should run the placeholder test
4. `npm run build` — Should create `dist/` with all bundles
5. `npm run dev` — Should launch the app with hot reload

---

## Success Criteria
- [ ] All TypeScript compiles without errors
- [ ] ESLint passes
- [ ] Prettier formats consistently
- [ ] `npm run dev` launches the app
- [ ] Visualizer still animates at 120fps
- [ ] Chat still streams responses
- [ ] Metrics overlay still works

---

## Files Created/Modified Summary
- `tsconfig.json`, `tsconfig.main.json`, `tsconfig.preload.json`, `tsconfig.renderer.json`
- `vite.config.ts`, `vitest.config.ts`
- `.eslintrc.cjs`, `.prettierrc`, `.prettierignore`
- `src/main/index.ts`
- `src/preload/index.ts`
- `src/renderer/main.ts`, `src/renderer/index.html`, `src/renderer/styles.css`
- `src/shared/types.ts`, `src/shared/types.test.ts`
- `src/api/openai-stream.ts`
- Updated `package.json`

