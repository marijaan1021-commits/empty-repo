(function () {
  const vscode = acquireVsCodeApi();
  const screen = document.getElementById("screen");
  const placeholder = document.getElementById("placeholder");
  const statusEl = document.getElementById("status");

  let naturalW = 0;
  let naturalH = 0;
  let pending = false;
  let frames = 0;

  function setStatus(text) {
    statusEl.textContent = text;
  }

  function showFrame(data, width, height, count) {
    naturalW = width || naturalW;
    naturalH = height || naturalH;
    frames = count || frames;
    placeholder.style.display = "none";
    screen.style.display = "block";
    setStatus(frames + " frames");
    // Acknowledge only once the browser has DECODED the frame. The extension
    // keeps at most one frame in flight, so a slow browser can never build up
    // a queue of frames - that queue is what made the picture update in
    // bursts and delayed the input messages travelling in the same channel.
    screen.onload = () => vscode.postMessage({ type: "ack" });
    screen.onerror = () => vscode.postMessage({ type: "ack" });
    screen.src = "data:image/png;base64," + data;
  }

  window.addEventListener("message", (event) => {
    const msg = event.data;
    if (!msg || typeof msg !== "object") return;
    switch (msg.type) {
      case "frame":
        showFrame(msg.data, msg.width, msg.height, msg.frames);
        break;
      case "status":
        setStatus(msg.device + " · " + msg.state);
        break;
      case "log":
        setStatus(msg.message);
        break;
    }
  });

  function send(action, extra) {
    vscode.postMessage(Object.assign({ type: "input", action: action }, extra || {}));
  }

  // One pointer gesture = one action.
  //
  // The tap is dispatched on pointerdown, not pointerup: the frame image is
  // replaced ~1-2 times per second, and a gesture that starts while the
  // browser is swapping the image can lose its pointerup (pointercancel),
  // which silently swallowed most of the taps. A short timer is used to
  // upgrade the gesture to a swipe when the pointer actually moves.
  let downAt = null;
  let tapTimer = null;

  function toDevice(event) {
    const rect = contentRect();
    return {
      x: Math.round(((event.clientX - rect.left) / rect.width) * naturalW),
      y: Math.round(((event.clientY - rect.top) / rect.height) * naturalH),
    };
  }

  // The <img> is scaled to the panel, so the element box is not the same as
  // the visible image: with object-fit:contain the picture is letterboxed
  // inside the box. Compute the real picture rectangle so taps land on the
  // right pixel.
  function contentRect() {
    const box = screen.getBoundingClientRect();
    if (!naturalW || !naturalH) return box;
    const scale = Math.min(box.width / naturalW, box.height / naturalH);
    const w = naturalW * scale;
    const h = naturalH * scale;
    return {
      left: box.left + (box.width - w) / 2,
      top: box.top + (box.height - h) / 2,
      width: w || box.width,
      height: h || box.height,
    };
  }

  screen.addEventListener("pointerdown", (event) => {
    event.preventDefault();
    if (!naturalW || !naturalH) return;
    downAt = { clientX: event.clientX, clientY: event.clientY, ...toDevice(event) };
    try { screen.setPointerCapture(event.pointerId); } catch (_) {}
    if (tapTimer) clearTimeout(tapTimer);
    tapTimer = setTimeout(() => {
      tapTimer = null;
      if (!downAt) return;
      send("tap", { x: downAt.x, y: downAt.y });
      downAt = null;
    }, 70);
  });

  screen.addEventListener("pointermove", (event) => {
    if (!downAt) return;
    // A drag has to be a real drag: the button must still be held and the
    // pointer must have travelled a real distance. The frame image is
    // swapped under the pointer constantly, which used to produce phantom
    // moves that turned plain clicks into swipes (and a swipe on the + button
    // does nothing).
    if (!event.buttons) return;
    if (Math.hypot(event.clientX - downAt.clientX, event.clientY - downAt.clientY) > 30) {
      // It is a drag: cancel the pending tap and remember the start point.
      if (tapTimer) { clearTimeout(tapTimer); tapTimer = null; }
      downAt.dragging = true;
    }
  });

  screen.addEventListener("pointerup", (event) => {
    if (!downAt) return;
    if (downAt.dragging) {
      // A drag: cancel the pending tap and send the swipe instead.
      if (tapTimer) { clearTimeout(tapTimer); tapTimer = null; }
      const end = toDevice(event);
      send("swipe", { x1: downAt.x, y1: downAt.y, x2: end.x, y2: end.y, ms: 300 });
      downAt = null;
      return;
    }
    // A plain tap. The pending timer delivers it exactly once, 120 ms after
    // pointerdown. If that timer already fired, the tap was already sent -
    // sending another one here would register the tap twice.
  });

  screen.addEventListener("pointercancel", () => {
    // A pointercancel is usually NOT a real gesture abort: the frame image is
    // swapped underneath the pointer every time the screen changes, and the
    // browser cancels the gesture when that happens. A pending tap therefore
    // survives a cancel - only a drag (which is already a swipe) is dropped.
    if (!downAt || !downAt.dragging) return;
    if (tapTimer) { clearTimeout(tapTimer); tapTimer = null; }
    downAt = null;
  });

  document.querySelectorAll(".bar button").forEach((btn) => {
    btn.addEventListener("click", () => send("key", { code: btn.dataset.key }));
  });

  window.addEventListener("keydown", (event) => {
    const map = {
      Enter: 66,
      Backspace: 67,
      Tab: 61,
      Escape: 111,
      Delete: 112,
      ArrowUp: 19,
      ArrowDown: 20,
      ArrowLeft: 21,
      ArrowRight: 22,
      Home: 122,
      End: 123,
      PageUp: 92,
      PageDown: 93,
    };
    if (event.key === "Backspace") {
      send("key", { code: 67 });
      event.preventDefault();
      return;
    }
    if (map[event.key] !== undefined) {
      send("key", { code: map[event.key] });
      event.preventDefault();
    }
  });

  vscode.postMessage({ type: "ready" });
})();
