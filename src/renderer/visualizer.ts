import * as THREE from 'three';
import type { VisualizerState, ProcessMetrics } from '@shared/types';

const canvas = document.getElementById('visualizer-canvas') as HTMLCanvasElement | null;
if (!canvas) {
  throw new Error('Visualizer canvas not found in DOM.');
}

const overlayFps = document.getElementById('metric-fps');
const overlayCpu = document.getElementById('metric-cpu');
const overlayMem = document.getElementById('metric-mem');
const overlayFooter = document.querySelector('#metrics-panel .metric-footer');
const defaultFooterText = overlayFooter?.textContent ?? '';

function markMetricsUnavailable(reason: string) {
  if (overlayFooter) {
    overlayFooter.textContent = reason;
  }
}

function restoreFooterText() {
  if (overlayFooter) {
    overlayFooter.textContent = defaultFooterText;
  }
}

function updateFpsDisplay(fpsValue: number) {
  if (overlayFps) {
    overlayFps.textContent = fpsValue.toFixed(1);
  }
}

async function refreshNodeMetrics(): Promise<void> {
  if (!window.hologram?.getMetrics) {
    markMetricsUnavailable('Metrics API unavailable');
    console.warn('hologram.getMetrics is not exposed in the renderer.');
    return;
  }

  try {
    const metrics: ProcessMetrics = await window.hologram.getMetrics();
    if (!metrics) {
      markMetricsUnavailable('Metrics call returned no data');
      return;
    }

    restoreFooterText();

    if (overlayCpu) {
      overlayCpu.textContent = `${metrics.cpuPercent.toFixed(1)}%`;
    }
    if (overlayMem) {
      overlayMem.textContent = `${metrics.heapUsedMB.toFixed(1)} MB`;
    }
  } catch (err) {
    markMetricsUnavailable('Metrics fetch failed');
    console.error('Failed to get metrics:', err);
  }
}

setInterval(refreshNodeMetrics, 1500);
refreshNodeMetrics();

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(60, window.innerWidth / window.innerHeight, 0.1, 100);
camera.position.z = 2.8;

const renderer = new THREE.WebGLRenderer({
  canvas,
  alpha: true,
  antialias: true,
  powerPreference: 'high-performance',
});

renderer.setPixelRatio(window.devicePixelRatio);
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.setClearColor(0x000000, 0);

scene.add(new THREE.PointLight(0xffffff, 1.35));
scene.add(new THREE.AmbientLight(0x6677ff, 0.9));

const vertexShader = `
  uniform float uTime;
  uniform float uBreathSpeed;
  uniform float uBreathScale;

  varying vec3 vPosition;

  void main() {
    vPosition = position;
    float breath = sin(uTime * uBreathSpeed) * uBreathScale + 1.0;
    vec3 newPosition = position * breath;
    float jitter = sin(position.x * 10.0 + uTime * 0.5) * 0.02;
    newPosition += normal * jitter;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(newPosition, 1.0);
    gl_PointSize = 3.5;
  }
`;

const fragmentShader = `
  uniform vec3 uColor;
  uniform float uOpacity;

  void main() {
    vec2 center = gl_PointCoord - vec2(0.5);
    float dist = length(center);
    if (dist > 0.5) discard;
    float alpha = smoothstep(0.5, 0.2, dist) * uOpacity;
    gl_FragColor = vec4(uColor, alpha);
  }
`;

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

interface StateConfig {
  color: THREE.Color;
  breathSpeed: number;
  breathScale: number;
  transitionDuration: number;
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

let currentVisualizerState: VisualizerState = 'idle';
let targetConfig = stateConfigs.idle;
let fromConfig: StateConfig = stateConfigs.idle;
let transitionStart = 0;
let isTransitioning = false;

function easeOutCubic(t: number): number {
  return 1 - Math.pow(1 - t, 3);
}

function lerpConfig(from: StateConfig, to: StateConfig, t: number): void {
  const eased = easeOutCubic(t);
  const currentColor = new THREE.Color().lerpColors(from.color, to.color, eased);
  shaderMaterial.uniforms.uColor.value = currentColor;
  shaderMaterial.uniforms.uBreathSpeed.value =
    from.breathSpeed + (to.breathSpeed - from.breathSpeed) * eased;
  shaderMaterial.uniforms.uBreathScale.value =
    from.breathScale + (to.breathScale - from.breathScale) * eased;
}

export function setVisualizerState(state: VisualizerState): void {
  if (state === currentVisualizerState) return;
  fromConfig = {
    color: shaderMaterial.uniforms.uColor.value.clone(),
    breathSpeed: shaderMaterial.uniforms.uBreathSpeed.value,
    breathScale: shaderMaterial.uniforms.uBreathScale.value,
    transitionDuration: 0,
  };
  targetConfig = stateConfigs[state] ?? stateConfigs.idle;
  transitionStart = performance.now();
  isTransitioning = true;
  currentVisualizerState = state;
}

window.setVisualizerState = setVisualizerState;

const outerGeometry = new THREE.IcosahedronGeometry(1.4, 5);
const particles = new THREE.Points(outerGeometry, shaderMaterial);
scene.add(particles);

const innerMaterial = shaderMaterial.clone();
innerMaterial.uniforms.uColor.value = new THREE.Color(0xff99ff);
innerMaterial.uniforms.uOpacity.value = 0.65;
const innerSphere = new THREE.Points(new THREE.IcosahedronGeometry(1.0, 4), innerMaterial);
scene.add(innerSphere);

function resize(): void {
  const width = window.innerWidth;
  const height = window.innerHeight;
  renderer.setSize(width, height);
  camera.aspect = width / height;
  camera.updateProjectionMatrix();
}

window.addEventListener('resize', resize);
resize();

let lastMetricUpdate = performance.now();
let fpsFrameCount = 0;

function animate(timestamp: number): void {
  requestAnimationFrame(animate);

  shaderMaterial.uniforms.uTime.value = timestamp * 0.001;
  innerMaterial.uniforms.uTime.value = timestamp * 0.001;

  if (isTransitioning) {
    const elapsed = timestamp - transitionStart;
    const progress = Math.min(elapsed / targetConfig.transitionDuration, 1);
    lerpConfig(fromConfig, targetConfig, progress);
    innerMaterial.uniforms.uBreathSpeed.value = shaderMaterial.uniforms.uBreathSpeed.value * 0.8;
    innerMaterial.uniforms.uBreathScale.value = shaderMaterial.uniforms.uBreathScale.value * 0.7;
    if (progress >= 1) {
      isTransitioning = false;
    }
  }

  particles.rotation.y += 0.0012;
  particles.rotation.z += 0.0006;
  innerSphere.rotation.y -= 0.0015;
  innerSphere.rotation.x += 0.0005;

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
