// RNNoise (ML noise suppression) wrapper — the one clean boundary Dart calls.
//
// window.albineDenoise(Float32Array samples, Number sampleRate)
//   -> Promise<Float32Array>   // denoised mono @ 48 kHz
//
// All the emscripten memory juggling stays here in JS (natural), so the Dart
// side just hands over PCM and gets clean PCM back. RNNoise operates on 48 kHz
// mono in 480-sample (10 ms) frames, with samples scaled to the int16 range.
// On any failure it returns the original samples unchanged (fail-open — a
// voice note must still send even if denoising can't run).
(function () {
  "use strict";

  var modulePromise = null;
  function getModule() {
    if (!modulePromise) {
      if (typeof createRNNWasmModule !== "function") {
        return Promise.reject(new Error("rnnoise.js not loaded"));
      }
      // No locateFile override needed: emscripten derives the .wasm URL from
      // rnnoise.js's own <script> src, which already carries the base path
      // (works both on localhost "/" and GitHub Pages "/albine-messenger/").
      modulePromise = createRNNWasmModule();
    }
    return modulePromise;
  }

  function resampleTo48k(input, inRate) {
    if (!inRate || inRate === 48000) return input;
    var ratio = 48000 / inRate;
    var outLen = Math.max(1, Math.round(input.length * ratio));
    var out = new Float32Array(outLen);
    for (var i = 0; i < outLen; i++) {
      var src = i / ratio;
      var i0 = Math.floor(src);
      var i1 = Math.min(i0 + 1, input.length - 1);
      var t = src - i0;
      out[i] = input[i0] * (1 - t) + input[i1] * t;
    }
    return out;
  }

  window.albineDenoise = async function (samples, sampleRate) {
    try {
      var Module = await getModule();
      var pcm = resampleTo48k(samples, sampleRate);

      var FRAME = 480;
      var st = Module._rnnoise_create(0);
      var ptr = Module._malloc(FRAME * 4);
      var base = ptr >> 2;
      var out = new Float32Array(pcm.length);

      for (var off = 0; off < pcm.length; off += FRAME) {
        var heap = Module.HEAPF32; // re-read each frame in case the heap grew
        for (var j = 0; j < FRAME; j++) {
          var idx = off + j;
          heap[base + j] = idx < pcm.length ? pcm[idx] * 32768 : 0;
        }
        Module._rnnoise_process_frame(st, ptr, ptr);
        heap = Module.HEAPF32;
        for (var k = 0; k < FRAME; k++) {
          var oi = off + k;
          if (oi < out.length) out[oi] = heap[base + k] / 32768;
        }
      }

      Module._free(ptr);
      Module._rnnoise_destroy(st);
      return out;
    } catch (e) {
      console.warn("[rnnoise] denoise failed, using original audio", e);
      return samples;
    }
  };
})();
