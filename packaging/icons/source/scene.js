// A 3D axial resistor, rendered square on a transparent background.
// Units: the body is about 3.5 long; the scene's floor is y = 0.
import * as THREE from 'three';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';

const SIZE = window.ICON_SIZE || 1024;
const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, preserveDrawingBuffer: true });
renderer.setPixelRatio(1);
renderer.setSize(SIZE, SIZE);
renderer.setClearColor(0x000000, 0);
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.NeutralToneMapping;
renderer.toneMappingExposure = 0.95;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
document.body.appendChild(renderer.domElement);

const scene = new THREE.Scene();
const pmrem = new THREE.PMREMGenerator(renderer);
scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
scene.environmentIntensity = 0.75;

// --- body: a lathe of the dog-bone profile, axis along y -----------------------
const R_MID = 0.5, R_CAP = 0.64, HALF = 1.72;
const profile = new THREE.SplineCurve([
  new THREE.Vector2(0.07, -HALF),
  new THREE.Vector2(0.30, -HALF + 0.04),
  new THREE.Vector2(0.50, -HALF + 0.14),
  new THREE.Vector2(0.62, -1.38),
  new THREE.Vector2(R_CAP, -1.16),
  new THREE.Vector2(0.60, -0.94),
  new THREE.Vector2(0.52, -0.74),
  new THREE.Vector2(R_MID, -0.5),
  new THREE.Vector2(R_MID, 0.5),
  new THREE.Vector2(0.52, 0.74),
  new THREE.Vector2(0.60, 0.94),
  new THREE.Vector2(R_CAP, 1.16),
  new THREE.Vector2(0.62, 1.38),
  new THREE.Vector2(0.50, HALF - 0.14),
  new THREE.Vector2(0.30, HALF - 0.04),
  new THREE.Vector2(0.07, HALF),
]).getSpacedPoints(600);
const body = new THREE.LatheGeometry(profile, 160);

// Bands by axial position: brown, black, red, then a gap and gold.
const beige = new THREE.Color('#C49C70');
const bands = [
  [ 1.02,  1.30, new THREE.Color('#5E2C12'), 0.0],   // brown, on the first cap
  [ 0.38,  0.62, new THREE.Color('#141217'), 0.0],   // black
  [-0.12,  0.12, new THREE.Color('#A8200F'), 0.0],   // red
  [-1.30, -1.02, new THREE.Color('#C9962E'), 1.0],   // gold, on the far cap
];
const pos = body.attributes.position;
const colors = new Float32Array(pos.count * 3);
const metal = new Float32Array(pos.count);
for (let i = 0; i < pos.count; i++) {
  const y = pos.getY(i);
  let c = beige, m = 0;
  for (const [a, b, col, mt] of bands) if (y >= a && y <= b) { c = col; m = mt; }
  colors.set([c.r, c.g, c.b], i * 3);
  metal[i] = m;
}
body.setAttribute('color', new THREE.BufferAttribute(colors, 3));
body.setAttribute('metal', new THREE.BufferAttribute(metal, 1));

const bodyMat = new THREE.MeshPhysicalMaterial({
  vertexColors: true, roughness: 0.55, metalness: 0.0,
  clearcoat: 0.7, clearcoatRoughness: 0.28,
});
// Let the gold band read as metallic paint.
bodyMat.onBeforeCompile = (shader) => {
  shader.vertexShader = shader.vertexShader
    .replace('#include <common>', '#include <common>\nattribute float metal;\nvarying float vMetal;')
    .replace('#include <begin_vertex>', '#include <begin_vertex>\nvMetal = metal;');
  shader.fragmentShader = shader.fragmentShader
    .replace('#include <common>', '#include <common>\nvarying float vMetal;')
    .replace('#include <metalnessmap_fragment>', '#include <metalnessmap_fragment>\nmetalnessFactor = mix(metalnessFactor, 0.9, vMetal);')
    .replace('#include <roughnessmap_fragment>', '#include <roughnessmap_fragment>\nroughnessFactor = mix(roughnessFactor, 0.3, vMetal);');
};
const bodyMesh = new THREE.Mesh(body, bodyMat);
bodyMesh.castShadow = true;

// --- leads: tinned copper wire with rounded ends ---------------------------------
const leadMat = new THREE.MeshStandardMaterial({ color: '#D8DCE3', metalness: 1.0, roughness: 0.22 });
const LEAD_R = 0.075, LEAD_LEN = 0.62;
const resistor = new THREE.Group();
resistor.add(bodyMesh);
for (const s of [-1, 1]) {
  const wire = new THREE.Mesh(new THREE.CylinderGeometry(LEAD_R, LEAD_R, LEAD_LEN, 48), leadMat);
  wire.position.y = s * (HALF - 0.05 + LEAD_LEN / 2);
  const tip = new THREE.Mesh(new THREE.SphereGeometry(LEAD_R, 48, 24), leadMat);
  tip.position.y = s * (HALF - 0.05 + LEAD_LEN);
  wire.castShadow = tip.castShadow = true;
  resistor.add(wire, tip);
}

// Lay it on the floor, axis horizontal, turned so it runs corner to corner.
resistor.rotation.z = Math.PI / 2;
const holder = new THREE.Group();
holder.add(resistor);
holder.position.y = R_CAP;
holder.rotation.y = THREE.MathUtils.degToRad(window.YAW ?? 36);
scene.add(holder);

// --- floor that only shows the shadow --------------------------------------------
const floor = new THREE.Mesh(new THREE.PlaneGeometry(20, 20), new THREE.ShadowMaterial({ opacity: 0.26 }));
floor.rotation.x = -Math.PI / 2;
floor.receiveShadow = true;
scene.add(floor);

// --- lights ------------------------------------------------------------------------
const key = new THREE.DirectionalLight('#fff4e6', 2.8);
key.position.set(-2.5, 7, 3.5);
key.castShadow = true;
key.shadow.mapSize.set(2048, 2048);
key.shadow.radius = 10;
key.shadow.blurSamples = 24;
Object.assign(key.shadow.camera, { left: -4, right: 4, top: 4, bottom: -4, near: 0.5, far: 20 });
scene.add(key);
const rim = new THREE.DirectionalLight('#cfe0ff', 0.9);
rim.position.set(4, 2.5, -4);
scene.add(rim);

// --- camera: above and in front, framing the part with margin ----------------------
const camera = new THREE.PerspectiveCamera(window.FOV ?? 30, 1, 0.1, 100);
camera.position.set(0, window.CAM_Y ?? 7.9, window.CAM_Z ?? 8.4);
camera.lookAt(0, 0.2, 0);

renderer.render(scene, camera);
window.RENDERED = true;
