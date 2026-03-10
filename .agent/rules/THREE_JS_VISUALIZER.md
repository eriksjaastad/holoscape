# The Cortana Core Visualizer - Three.js Code

**Date:** December 18, 2025
**Source:** Gemini
**Status:** COMPLETE, RUNNABLE CODE! 🎉

---

## Overview

This document details the Three.js code for creating the "Breathing Particle Sphere," a core visual element of the Cortana interface. This visualization consists of two nested, counter-rotating particle spheres with a "breathing" effect, designed to evoke a sense of a dormant AI awaiting input. The code is designed to be easily integrated into an HTML environment, particularly within an Electron application where a transparent background is desired.

## What This Is

**The "Breathing Particle Sphere"** - The centerpiece of the Cortana interface.

This creates a swirling cloud of data points waiting for input - like a dormant Cortana AI. It's inspired by the center of Sonique's player, but with modern 3D graphics.

---

## What It Does

### Two Nested Spheres
- **Outer sphere:** Classic Cortana blue (`0x00aaff`)
- **Inner sphere:** Deeper purple/blue (`0x5522ff`)
- Made of PARTICLES (not solid) - looks like a hologram!

### Counter-Rotation
- Outer: Rotates one direction
- Inner: Rotates opposite direction (faster)
- Creates visual complexity and movement

### The "Breathing" Effect
- Slowly pulses in size (sine wave)
- Expands and contracts
- Feels organic, alive
- Like it's idling, waiting for commands

### Additive Blending
- When particles overlap, they glow brighter
- Creates an "energy field" effect
- Halo technology aesthetic

---

## Implementation Details

The visualization is built using Three.js, a JavaScript 3D library. Key features include:

*   **Particle System:** The spheres are rendered using `THREE.Points`, creating a holographic effect.
*   **Icosahedron Geometry:**  An `IcosahedronGeometry` is used to create a faceted, techy look, rather than a perfectly smooth sphere.
*   **Additive Blending:** `THREE.AdditiveBlending` is used to create a glowing effect where particles overlap.
*   **Transparency:** The renderer and materials are configured for transparency, allowing the visualization to be overlaid on other UI elements.
*   **Animation Loop:** The `animate()` function updates the rotation and scale of the spheres to create the breathing and counter-rotation effects.

## The Complete Code

**File:** `cortana-core.html` (or integrate into `index.html`)

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Cortana Core Visualization</title>
    <style>
        body {
            margin: 0;
            /* Transparent background for Electron */
            background-color: transparent; 
            overflow: hidden; /* No scrollbars */
            /* Canvas sits behind other UI elements */
            z-index: -1;
            position: fixed;
            top: 0; left: 0;
        }
        canvas {
            display: block;
        }
    </style>
</head>
<body>

<script type="importmap">
  {
    "imports": {
      "three": "https://unpkg.com/three@0.160.0/build/three.module.js",
      "three/addons/": "https://unpkg.com/three@0.160.0/examples/jsm/"
    }
  }
</script>

<script type="module">
    import * as THREE from 'three';

    // --- SETUP ---
    const scene = new THREE.Scene();
    
    // Create camera with tight field of view for "gadget" feel
    const camera = new THREE.PerspectiveCamera(75, window.innerWidth / window.innerHeight, 0.1, 1000);
    camera.position.z = 3;

    // Renderer with alpha:true for transparent background
    const renderer = new THREE.WebGLRenderer({ alpha: true, antialias: true });
    renderer.setSize(window.innerWidth, window.innerHeight);
    // Make clear color transparent
    renderer.setClearColor( 0x000000, 0 ); 
    document.body.appendChild(renderer.domElement);

    // --- CORTANA CORE GEOMETRY ---

    // IcosahedronGeometry for techy, faceted look (not smooth sphere)
    // Radius 1.2, Detail level 4 (higher = more points)
    const geometry = new THREE.IcosahedronGeometry(1.2, 4);

    // OUTER SPHERE MATERIAL: The "Hologram" look
    // PointsMaterial renders dots instead of solid faces
    const materialOuter = new THREE.PointsMaterial({
        color: 0x00aaff, // Classic Cortana Blue
        size: 0.03,      // Size of individual dots
        transparent: true,
        opacity: 0.8,
        blending: THREE.AdditiveBlending // Overlapping dots glow brighter!
    });

    // Create the outer particle sphere
    const sphereOuter = new THREE.Points(geometry, materialOuter);
    scene.add(sphereOuter);

    // INNER SPHERE: Denser, different color for depth
    const materialInner = new THREE.PointsMaterial({
        color: 0x5522ff, // Deeper purple/blue
        size: 0.02,
        transparent: true,
        opacity: 0.6,
        blending: THREE.AdditiveBlending
    });
    const sphereInner = new THREE.Points(geometry, materialInner);
    sphereInner.scale.set(0.7, 0.7, 0.7); // Smaller
    scene.add(sphereInner);


    // --- ANIMATION LOOP ---
    function animate() {
        requestAnimationFrame(animate);

        const time = Date.now() * 0.001; // Time in seconds

        // 1. ROTATION (Counter-rotation creates complexity)
        sphereOuter.rotation.y += 0.002;
        sphereInner.rotation.y -= 0.004; // Rotate faster, opposite direction

        // 2. "BREATHING" (Scale pulsates with sine wave)
        const scale = 0.05 * Math.sin(time * 0.5) + 0.95; // Range: 0.9 to 1.0
        sphereOuter.scale.set(scale, scale, scale);
        sphereInner.scale.set(scale, scale, scale);

        renderer.render(scene, camera);
    }

    animate();

    // --- RESIZE HANDLER ---
    // Keep aspect ratio correct on window resize
    window.addEventListener('resize', () => {
        const width = window.innerWidth;
        const height = window.innerHeight;
        renderer.setSize(width, height);
        camera.aspect = width / height;
        camera.updateProjectionMatrix();
    });

</script>

</body>
</html>
