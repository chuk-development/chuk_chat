// agents-browser-mcp init script for a box WITHOUT a GPU (a VPS, a headless
// server). browser-mcp.sh passes it with --init-script only when the
// container has no GPU.
//
// With no GPU, Chrome draws WebGL with SwiftShader and says so in
// WEBGL_debug_renderer_info: "ANGLE (Google, Vulkan 1.3.0 (SwiftShader
// Device (Subzero)...)". That is the strongest bot tell. This script makes
// the main thread report a common Linux laptop GPU instead (Intel UHD 620 on
// Mesa, the string a real Linux Chrome sends), for WebGL1 and WebGL2, and
// the size limits of that GPU (SwiftShader: 8192, Intel on Mesa: 16384).
//
// It changes values only when the real renderer is a software one
// (SwiftShader, llvmpipe). The patched functions are Proxies of the
// originals, so name and length stay native, and Function.prototype.toString
// gives "function getParameter() { [native code] }" for them (a bare Proxy
// would give "function () { [native code] }", a known tell).
//
// What can still see through it:
// - The rendering itself. A hash of WebGL or canvas pixels is SwiftShader's,
//   not Intel's. A site that keeps a hash database per GPU can tell.
// - Workers. Playwright runs init scripts in pages and frames, not in
//   workers. An OffscreenCanvas in a worker still says SwiftShader (creepjs
//   compares the two).
// - Deep lie checks: an error thrown through a Proxy has one extra frame in
//   its stack.
// The real fix is a real GPU (docker.py gives an NVIDIA GPU to the box).
(() => {
  const VENDOR = "Google Inc. (Intel)";
  const RENDERER = "ANGLE (Intel, Mesa Intel(R) UHD Graphics 620 (KBL GT2), OpenGL 4.6)";
  const LIMIT = 16384;
  const UNMASKED_VENDOR = 0x9245;
  const UNMASKED_RENDERER = 0x9246;
  const SIZE_LIMITS = new Set([
    0x0d33, // MAX_TEXTURE_SIZE
    0x84e8, // MAX_RENDERBUFFER_SIZE
    0x851c, // MAX_CUBE_MAP_TEXTURE_SIZE
  ]);
  const MAX_VIEWPORT_DIMS = 0x0d3a;

  const names = new WeakMap();
  const nativeToString = Function.prototype.toString;
  const toString = new Proxy(nativeToString, {
    apply(target, self, args) {
      const name = names.get(self);
      if (name !== undefined) return `function ${name}() { [native code] }`;
      return Reflect.apply(target, self, args);
    },
  });
  names.set(toString, "toString");
  Object.defineProperty(Function.prototype, "toString", {
    ...Object.getOwnPropertyDescriptor(Function.prototype, "toString"),
    value: toString,
  });

  const nativeGetParameter =
    window.WebGLRenderingContext && window.WebGLRenderingContext.prototype.getParameter;
  let software;
  const isSoftware = () => {
    if (software === undefined) {
      software = false;
      try {
        // A canvas of our own, so the page's context gets no GL error.
        const gl = document.createElement("canvas").getContext("webgl");
        const ext = gl && gl.getExtension("WEBGL_debug_renderer_info");
        const real = ext ? Reflect.apply(nativeGetParameter, gl, [ext.UNMASKED_RENDERER_WEBGL]) : "";
        software = /SwiftShader|llvmpipe|softpipe/i.test(String(real));
      } catch (_) {
        software = false;
      }
    }
    return software;
  };

  for (const name of ["WebGLRenderingContext", "WebGL2RenderingContext"]) {
    const Context = window[name];
    if (!Context) continue;
    const descriptor = Object.getOwnPropertyDescriptor(Context.prototype, "getParameter");
    if (!descriptor || typeof descriptor.value !== "function") continue;
    const original = descriptor.value;
    const patched = new Proxy(original, {
      apply(target, self, args) {
        // The native call first: a wrong `this` or argument throws as usual.
        const value = Reflect.apply(target, self, args);
        if (value === null || !nativeGetParameter || !isSoftware()) return value;
        const pname = args[0];
        if (pname === UNMASKED_VENDOR) return VENDOR;
        if (pname === UNMASKED_RENDERER) return RENDERER;
        if (SIZE_LIMITS.has(pname)) return LIMIT;
        if (pname === MAX_VIEWPORT_DIMS) return new Int32Array([LIMIT, LIMIT]);
        return value;
      },
    });
    names.set(patched, "getParameter");
    Object.defineProperty(Context.prototype, "getParameter", { ...descriptor, value: patched });
  }
})();
