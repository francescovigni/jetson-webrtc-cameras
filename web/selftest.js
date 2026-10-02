// Selector self-check for the player page. Paste into the browser console, or:
//   fetch('/selftest.js').then(r => r.text()).then(eval)
//
// Asserts against the page's OWN resolver (window.__resolveCam), not a copy of
// its logic — a test that reimplements the thing it checks passes even when the
// production code is wrong.
(function () {
  const results = [];
  const check = (name, got, want) => {
    const ok = got === want;
    results.push(`${ok ? "PASS" : "FAIL"}  ${name}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
    return ok;
  };

  // 1. The selector offers exactly the cameras the container generated. Both
  //    sides come from cameras.json, so this holds for any set of backends.
  const sel = document.getElementById("cam");
  const configured = Object.keys(window.__CAMS || {});
  check("selector present", !!sel, true);
  check("at least one camera configured", configured.length > 0, true);
  check("option count matches cameras.json", sel ? sel.options.length : 0, configured.length);
  check("option values match cameras.json",
        sel ? [...sel.options].map(o => o.value).join(",") : "", configured.join(","));

  // 2. The selector reflects the camera actually being played.
  check("selector matches active camera", sel ? sel.value : "", window.__activeCam);

  // 3. A stored value that is not a camera must not be used. "constructor" and
  //    "toString" are the nasty ones: truthy on every object, so a plain
  //    `CAMS[stored]` test would wrongly accept them and strand the player on a
  //    path that 404s forever.
  if (typeof window.__resolveCam !== "function") {
    results.push("FAIL  resolver exposed: window.__resolveCam is not a function");
  } else {
    // The fallback is whatever the container put first in cameras.json.
    const fallback = configured[0];
    for (const bad of ["cam", "", null, "constructor", "toString", "__proto__",
                       "nosuchcamera", (configured[0] || "x") + " "]) {
      check(`rejects stored ${JSON.stringify(bad)}`, window.__resolveCam(bad), fallback);
    }
    // ...and every configured camera must survive it.
    for (const good of configured) {
      check(`accepts stored ${JSON.stringify(good)}`, window.__resolveCam(good), good);
    }
  }

  // 4. A track that arrives with no MediaStream must never clear one that is
  //    already playing. MediaMTX answers a video-only path with an empty audio
  //    m-line carrying no a=msid, so ontrack fires a second time with
  //    e.streams empty — assigning e.streams[0] there wipes the live video.
  if (typeof window.__streamToBind !== "function") {
    results.push("FAIL  binder exposed: window.__streamToBind is not a function");
  } else {
    const a = new MediaStream();
    const b = new MediaStream();
    check("binds the first stream", window.__streamToBind([a], null), a);
    check("rebinds a different stream", window.__streamToBind([b], a), b);
    check("ignores a repeat of the bound stream", window.__streamToBind([a], a), null);
    check("ignores a track with no stream (csi audio m-line)", window.__streamToBind([], a), null);
    check("ignores a track with no stream when nothing is bound", window.__streamToBind([], null), null);
  }

  console.log(results.join("\n"));
  return results.every(r => r.startsWith("PASS")) ? "ALL PASS" : "FAILURES ABOVE";
})();
