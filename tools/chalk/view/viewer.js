// PBR viewer for baked Chalk scenes. A frame is many renders that are added up:
// each one has a different light from a studio dome and a sub-pixel camera shift.
// This gives soft shadows, contact shading and clean edges with no special pass.
import * as THREE from 'three';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';

const NAMED = {
  chrome: { metalness: 1, roughness: 0.07 }, metal: { metalness: 1, roughness: 0.3 }, brushed: { metalness: 1, roughness: 0.42 },
  cast: { metalness: 0.85, roughness: 0.62 }, paint: { metalness: 0.15, roughness: 0.32, clearcoat: 1, clearcoatRoughness: 0.08 },
  plastic: { metalness: 0, roughness: 0.42, clearcoat: 0.2, clearcoatRoughness: 0.4 }, matte: { metalness: 0, roughness: 0.62 },
  rubber: { metalness: 0, roughness: 0.88 }, fabric: { metalness: 0, roughness: 0.95, sheen: 1, sheenRoughness: 0.6 }, wood: { metalness: 0, roughness: 0.55, clearcoat: 0.3 },
  skin: { metalness: 0, roughness: 0.5, sheen: 0.6, sheenRoughness: 0.5 }, pcb: { metalness: 0.1, roughness: 0.38, clearcoat: 0.8, clearcoatRoughness: 0.25 },
  ceramic: { metalness: 0, roughness: 0.18, clearcoat: 1, clearcoatRoughness: 0.05 }, light: { metalness: 0, roughness: 0.4 },
  glass: { metalness: 0, roughness: 0.03, transparent: true, opacity: 0.5, clearcoat: 1, clearcoatRoughness: 0.02, depthWrite: false },
};
const BY_COLOR = { steel: 'metal', alu: 'brushed', darkmetal: 'metal', titanium: 'brushed', copper: 'metal', gold: 'metal', brass: 'metal', rubber: 'rubber', pcb: 'pcb', wood: 'wood', skin: 'skin', black: 'plastic', white: 'paint', plastic: 'plastic', dark: 'plastic', gray: 'plastic', red: 'paint', blue: 'paint', navy: 'paint', orange: 'paint', yellow: 'paint', green: 'paint', purple: 'paint', teal: 'paint', sky: 'paint', pink: 'plastic', jetgray: 'paint', camo: 'matte', brown: 'matte' };

function pickMat(m) {
  if (NAMED[m.mat] && m.mat !== 'metal' && m.mat !== 'matte') return m.mat;
  if (m.mat === 'metal') return BY_COLOR[m.name] && NAMED[BY_COLOR[m.name]].metalness === 1 ? BY_COLOR[m.name] : 'metal';
  return BY_COLOR[m.name] ?? (m.mat === 'matte' ? 'plastic' : 'plastic');
}

const float32 = (s) => { const b = atob(s), a = new Uint8Array(b.length); for (let i = 0; i < b.length; i++) a[i] = b.charCodeAt(i); return new Float32Array(a.buffer); };

const canvas = document.getElementById('c');
const renderer = new THREE.WebGLRenderer({ canvas, antialias: false, preserveDrawingBuffer: true, powerPreference: 'high-performance' });
renderer.setClearColor(0, 1);
renderer.toneMapping = THREE.NoToneMapping;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFShadowMap;
const scene = new THREE.Scene();
const pmrem = new THREE.PMREMGenerator(renderer);
scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.03).texture;
scene.environmentIntensity = 0.32;
const camera = new THREE.PerspectiveCamera(24, 16 / 9, 0.01, 1000);
const sun = new THREE.DirectionalLight(0xffffff, 1);
sun.castShadow = true;
sun.shadow.mapSize.set(2048, 2048);
sun.shadow.bias = -0.0002;
sun.shadow.normalBias = 0.012;
scene.add(sun, sun.target);

let data = null, groups = [], shellMats = [], size = [1280, 720], rtA, rtSum, frame = 0, radius = 1, centre = new THREE.Vector3(), floorMesh = null, user = null;
const quad = new THREE.Mesh(new THREE.PlaneGeometry(2, 2));
const quadScene = new THREE.Scene(); quadScene.add(quad);
const quadCam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
const addMat = new THREE.ShaderMaterial({ uniforms: { t: { value: null }, k: { value: 1 } }, depthTest: false, depthWrite: false, transparent: true, blending: THREE.CustomBlending, blendEquation: THREE.AddEquation, blendSrc: THREE.OneFactor, blendDst: THREE.OneFactor,
  vertexShader: 'varying vec2 v;void main(){v=uv;gl_Position=vec4(position.xy,0.,1.);}', fragmentShader: 'uniform sampler2D t;uniform float k;varying vec2 v;void main(){gl_FragColor=vec4(texture2D(t,v).rgb*k,1.);}' });
const outMat = new THREE.ShaderMaterial({ uniforms: { t: { value: null }, k: { value: 1 } }, depthTest: false, depthWrite: false,
  vertexShader: addMat.vertexShader, fragmentShader: `uniform sampler2D t;uniform float k;varying vec2 v;
  vec3 aces(vec3 x){return clamp((x*(2.51*x+.03))/(x*(2.43*x+.59)+.14),0.,1.);}
  float grain(vec2 p){return fract(sin(dot(p,vec2(12.9898,78.233)))*43758.5453)-.5;}
  void main(){vec3 c=texture2D(t,v).rgb*k;float d=length(v-.5);c*=1.-.28*d*d;
  c=aces(c*1.08);c=pow(c,vec3(1./2.2));c+=grain(gl_FragCoord.xy)/255.;gl_FragColor=vec4(c,1.);}` });

function targets() {
  rtA?.dispose(); rtSum?.dispose();
  const opt = { type: THREE.HalfFloatType, format: THREE.RGBAFormat, colorSpace: THREE.LinearSRGBColorSpace };
  rtA = new THREE.WebGLRenderTarget(size[0], size[1], { ...opt, samples: 4, stencilBuffer: true });
  rtSum = new THREE.WebGLRenderTarget(size[0], size[1], { ...opt, type: THREE.FloatType, depthBuffer: false });
}

function material(m) {
  const key = pickMat(m);
  const c = new THREE.Color().setRGB(...m.color.map((v) => (v / 255) ** 2.2));
  const p = new THREE.MeshPhysicalMaterial({ color: c, ...NAMED[key], side: THREE.DoubleSide });
  if (key === 'light') { p.emissive = c; p.emissiveIntensity = 2.5; }
  // The inside of a shell is dark, so glass shows a cabin and not bright paint.
  if (key !== 'glass') p.onBeforeCompile = (sh) => { sh.fragmentShader = sh.fragmentShader.replace('#include <color_fragment>', '#include <color_fragment>\n if (!gl_FrontFacing) diffuseColor.rgb = diffuseColor.rgb * 0.08 + 0.012;'); };
  return p;
}

function decalMat(d) {
  const H = 160, W = Math.min(4096, Math.round(H * d.aspect));
  const c = document.createElement('canvas'); c.width = W; c.height = H;
  const g = c.getContext('2d');
  g.fillStyle = d.color; g.textAlign = 'center'; g.textBaseline = 'middle';
  g.font = `${d.bold ? 800 : 600} ${H * 0.82}px Inter, Arial, sans-serif`;
  const w = g.measureText(d.text).width;
  if (w > W * 0.98) g.font = `${d.bold ? 800 : 600} ${H * 0.82 * W * 0.98 / w}px Inter, Arial, sans-serif`;
  g.fillText(d.text, W / 2, H / 2);
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace; t.anisotropy = 8;
  return new THREE.MeshPhysicalMaterial({ map: t, transparent: true, roughness: 0.4, clearcoat: 0.6, depthWrite: false, polygonOffset: true, polygonOffsetFactor: -3, polygonOffsetUnits: -3 });
}

function backdrop(lo, hi) {
  // A studio sweep: a floor that bends up into a wall, so there is no horizon line.
  const R = radius * 16, r = radius * 6, pts = [];
  pts.push(new THREE.Vector2(R * 1.5, 0));
  for (let i = 0; i <= 24; i++) { const a = (i / 24) * Math.PI / 2; pts.push(new THREE.Vector2(0, 0)); pts[pts.length - 1].set(-Math.sin(a) * r, r - Math.cos(a) * r); }
  pts.push(new THREE.Vector2(-r, R));
  const shape = pts;
  const g = new THREE.BufferGeometry(), v = [], idx = [];
  shape.forEach((p) => { v.push(-R * 2, p.y, p.x, R * 2, p.y, p.x); });
  for (let i = 0; i < shape.length - 1; i++) { const a = i * 2; idx.push(a, a + 1, a + 2, a + 1, a + 3, a + 2); }
  g.setAttribute('position', new THREE.Float32BufferAttribute(v, 3)); g.setIndex(idx); g.computeVertexNormals();
  const m = new THREE.Mesh(g, new THREE.MeshPhysicalMaterial({ color: new THREE.Color(0.2, 0.205, 0.215), roughness: 0.5, side: THREE.DoubleSide }));
  m.receiveShadow = true;
  return m;
}

// cut=z>0 or a free plane cut=nx,ny,nz,d. Everything with n.p > d goes away.
function cutPlane(text) {
  if (text.includes(',')) { const [a, b, c, k] = text.split(',').map(Number), n = new THREE.Vector3(a, b, c), l = n.length(); return new THREE.Plane(n.multiplyScalar(-1 / l), k / l); }
  const a = 'xyz'.indexOf(text[0]), sign = text[1] === '>' ? -1 : 1, n = new THREE.Vector3();
  n.setComponent(a, sign);
  return new THREE.Plane(n, -sign * Number(text.slice(2)));
}

// Solid cut faces: the stencil counts how many closed bodies a pixel of the plane is in.
function stencil(geo, cut) {
  const base = { depthWrite: false, depthTest: false, colorWrite: false, stencilWrite: true, stencilFunc: THREE.AlwaysStencilFunc, clippingPlanes: [cut] };
  return [[THREE.BackSide, THREE.IncrementWrapStencilOp], [THREE.FrontSide, THREE.DecrementWrapStencilOp]].map(([side, op]) => {
    const mesh = new THREE.Mesh(geo, new THREE.MeshBasicMaterial({ ...base, side, stencilFail: op, stencilZFail: op, stencilZPass: op }));
    mesh.renderOrder = 1;
    return mesh;
  });
}

function capPlane(cut, color) {
  const mat = new THREE.MeshPhysicalMaterial({ color: new THREE.Color(color), roughness: 0.55, clearcoat: 0.4, side: THREE.DoubleSide, stencilWrite: true, stencilRef: 0, stencilFunc: THREE.NotEqualStencilFunc, stencilFail: THREE.ReplaceStencilOp, stencilZFail: THREE.ReplaceStencilOp, stencilZPass: THREE.ReplaceStencilOp });
  const cap = new THREE.Mesh(new THREE.PlaneGeometry(radius * 8, radius * 8), mat);
  cut.coplanarPoint(cap.position);
  cap.lookAt(cap.position.clone().sub(cut.normal));
  cap.receiveShadow = true; cap.renderOrder = 1.1;
  cap.onAfterRender = (r) => r.clearStencil();
  return cap;
}

export function load(d) {
  data = d;
  d.fit = float32(d.fit);
  const [lo, hi] = d.box;
  centre.set((lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2);
  radius = Math.hypot(hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]) / 2 || 1;
  camera.near = radius * 0.05; camera.far = radius * 80;
  const cut = d.cut ? cutPlane(d.cut) : null;
  if (cut) renderer.localClippingEnabled = true;
  groups = d.groups.map((g) => {
    const o = new THREE.Group(); o.matrixAutoUpdate = false;
    const anyShell = d.groups.some((x) => x.meshes.some((m) => m.shell));
    const mats = g.meshes.map((m) => {
      const geo = new THREE.BufferGeometry();
      geo.setAttribute('position', new THREE.BufferAttribute(float32(m.pos), 3));
      geo.setAttribute('normal', new THREE.BufferAttribute(float32(m.nor), 3));
      if (m.decal) geo.setAttribute('uv', new THREE.BufferAttribute(float32(m.uv), 2));
      const mat = m.decal ? decalMat(m.decal) : material(m);
      if (cut && (m.shell || !anyShell)) { mat.clippingPlanes = [cut]; mat.clipShadows = true; }
      const mesh = new THREE.Mesh(geo, mat);
      if (cut && d.cap && m.shell) o.add(...stencil(geo, cut));
      mesh.castShadow = !m.decal && pickMat(m) !== 'glass'; mesh.receiveShadow = true;
      if (pickMat(m) === 'glass') mesh.renderOrder = 2; if (m.decal) mesh.renderOrder = 1;
      o.add(mesh);
      return mat;
    });
    scene.add(o);
    return { o, mats, base: mats.map((m) => m.emissive.clone()), M: g.matrices ? float32(g.matrices) : null, glow: g.glow ? float32(g.glow) : null };
  });
  if (cut && d.cap) scene.add(capPlane(cut, d.cap));
  floorMesh = backdrop(lo, hi);
  floorMesh.position.y = d.floor - radius * 0.002;
  scene.add(floorMesh);
  const s = sun.shadow.camera; const R = radius * 3.2;
  s.left = -R; s.right = R; s.top = R; s.bottom = -R; s.near = 0.01; s.far = R * 6; s.updateProjectionMatrix();
  sun.shadow.normalBias = radius * 0.004;
  return { tris: d.tris, parts: d.parts };
}

export function setSize(w, h) { size = [w, h]; renderer.setPixelRatio(1); renderer.setSize(w, h, false); camera.aspect = w / h; camera.updateProjectionMatrix(); targets(); }

export function setFrame(f) {
  frame = Math.min(data.frames - 1, Math.max(0, f));
  moment(frame);
  const c = user ?? data.camera[Math.min(frame, data.camera.length - 1)];
  aim(c);
  return data.captions[Math.min(frame, data.captions.length - 1)] ?? '';
}

// Parts at a moment between two frames. Poses are stored four times per frame.
function moment(t) {
  const sub = data.sub ?? 1, last = data.frames * sub - 1;
  const x = Math.min(last, t * sub), a = Math.floor(x), b = Math.min(last, a + 1), w = x - a;
  for (const g of groups) {
    if (!g.M) continue;
    const m = g.M, o = a * 13, q = b * 13;
    const v = (i) => m[o + i] + (m[q + i] - m[o + i]) * w;
    g.o.visible = m[o + 12] > 0.5;
    g.o.matrix.set(v(0), v(3), v(6), v(9), v(1), v(4), v(7), v(10), v(2), v(5), v(8), v(11), 0, 0, 0, 1);
    const k = g.glow[a];
    g.mats.forEach((mat, i) => { mat.emissive.copy(g.base[i]).lerp(new THREE.Color(1, 0.62, 0.12), k); mat.emissiveIntensity = k ? 0.9 : mat.emissiveIntensity; });
  }
  scene.updateMatrixWorld(true);
}

function aim([yaw, pitch, zoom, fx, fy, fz]) {
  const y = yaw * Math.PI / 180, p = pitch * Math.PI / 180;
  const back = new THREE.Vector3(-Math.cos(p) * Math.sin(y), Math.sin(p), Math.cos(p) * Math.cos(y));
  const right = new THREE.Vector3(Math.cos(y), 0, Math.sin(y));
  const up = new THREE.Vector3().crossVectors(back, right);
  const [lo, hi] = data.box;
  // Tight fit: find the box corners in camera space.
  let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9, z1 = -1e9;
  const P = data.fit, q = new THREE.Vector3();
  for (let i = 0; i < P.length; i += 3) {
    q.set(P[i], P[i + 1], P[i + 2]).sub(centre);
    const a = q.dot(right), b = q.dot(up); x0 = Math.min(x0, a); x1 = Math.max(x1, a); y0 = Math.min(y0, b); y1 = Math.max(y1, b); z1 = Math.max(z1, q.dot(back));
  }
  const tan = Math.tan(camera.fov * Math.PI / 360);
  const margin = 1.04;
  const dist = (Math.max((x1 - x0) / 2 / (tan * camera.aspect), (y1 - y0) / 2 / tan) * margin + z1) / (zoom || 1);
  const f = new THREE.Vector3(fx, fy, fz);
  if (Math.abs(fx - centre.x) + Math.abs(fy - centre.y) + Math.abs(fz - centre.z) < radius * 1e-3) f.addScaledVector(right, (x0 + x1) / 2).addScaledVector(up, (y0 + y1) / 2 - radius * 0.03);
  camera.position.copy(f).addScaledVector(back, dist);
  camera.up.set(0, 1, 0);
  camera.lookAt(f);
  camera.updateMatrixWorld(true);
}

// Halton sequence: stable, well spread samples, so every frame has the same noise.
const halton = (i, b) => { let f = 1, r = 0; while (i > 0) { f /= b; r += f * (i % b); i = Math.floor(i / b); } return r; };

export function render(samples = 32) {
  renderer.setRenderTarget(rtSum); renderer.setClearColor(0, 0); renderer.clear();
  const key = new THREE.Vector3(-0.55, 0.85, 0.65).normalize();
  const R = radius * 3;
  for (let i = 0; i < samples; i++) {
    const u = halton(i + 1, 2), v = halton(i + 1, 3), w = halton(i + 1, 5);
    let dir, power;
    if (i % 4 < 2) {
      // Large key softbox.
      const t = new THREE.Vector3(1, 0, 0).cross(key).normalize(), b = key.clone().cross(t);
      dir = key.clone().addScaledVector(t, (u - 0.5) * 0.9).addScaledVector(b, (v - 0.5) * 0.9).normalize();
      power = 3.4;
    } else {
      // Sky dome for soft occlusion.
      const z = 0.15 + 0.85 * u, a = v * Math.PI * 2, r = Math.sqrt(1 - z * z);
      dir = new THREE.Vector3(r * Math.cos(a), z, r * Math.sin(a));
      power = 1.5 * (0.6 + z);
    }
    sun.position.copy(centre).addScaledVector(dir, R);
    sun.target.position.copy(centre); sun.target.updateMatrixWorld();
    sun.intensity = power;
    camera.setViewOffset(size[0], size[1], halton(i + 1, 7) - 0.5, w - 0.5, size[0], size[1]);
    // Half a frame of shutter gives motion blur on rotors and fast parts.
    if (data.frames > 1) moment(frame + 0.5 * (i + 0.5) / samples);
    renderer.setRenderTarget(rtA);
    renderer.setClearColor(0x9ea0a6, 1);
    renderer.clear();
    renderer.render(scene, camera);
    addMat.uniforms.t.value = rtA.texture; addMat.uniforms.k.value = 1 / samples;
    quad.material = addMat;
    renderer.setRenderTarget(rtSum); renderer.autoClear = false;
    renderer.render(quadScene, quadCam);
    renderer.autoClear = true;
  }
  camera.clearViewOffset();
  outMat.uniforms.t.value = rtSum.texture;
  quad.material = outMat;
  renderer.setRenderTarget(null);
  renderer.render(quadScene, quadCam);
}

export function setCamera(c) { user = c; }
export const gpu = () => { const g = renderer.getContext(), e = g.getExtension('WEBGL_debug_renderer_info'); return e ? g.getParameter(e.UNMASKED_RENDERER_WEBGL) : '?'; };
export const info = () => renderer.info.render;
