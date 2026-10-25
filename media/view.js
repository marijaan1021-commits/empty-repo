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
    screen.src = "data:image/png;base64," + data;
    naturalW = width || naturalW;
    naturalH = height || naturalH;
    frames = count || frames;
    placeholder.style.display = "none";
    screen.style.display = "block";
    setStatus(frames + " frames");
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

  screen.addEventListener("pointerdown", (event) => {
    event.preventDefault();
    if (!naturalW || !naturalH) return;
    const rect = screen.getBoundingClientRect();
    const x = Math.round(((event.clientX - rect.left) / rect.width) * naturalW);
    const y = Math.round(((event.clientY - rect.top) / rect.height) * naturalH);
    send("tap", { x: x, y: y });
  });

  let downAt = null;
  screen.addEventListener("pointerdown", (event) => {
    downAt = { x: event.clientX, y: event.clientY };
  });
  screen.addEventListener("pointerup", (event) => {
    if (!downAt || !naturalW || !naturalH) return;
    const rect = screen.getBoundingClientRect();
    const x = Math.round(((event.clientX - rect.left) / rect.width) * naturalW);
    const y = Math.round(((event.clientY - rect.top) / rect.height) * naturalH);
    const dist = Math.hypot(event.clientX - downAt.x, event.clientY - downAt.y);
    if (dist > 12) {
      send("swipe", {
        x1: x, y1: y, x2: x, y2: y, ms: 300,
      });
    }
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
