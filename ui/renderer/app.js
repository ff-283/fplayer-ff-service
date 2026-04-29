const elGateway = document.getElementById("gatewayUrl");
const elApp = document.getElementById("appName");
const elStream = document.getElementById("streamName");
const elServiceMode = document.getElementById("serviceMode");
const elResult = document.getElementById("result");
const elStartupStatus = document.getElementById("startupStatus");
const btnCopyGateway = document.getElementById("btnCopyGateway");
const btnCopyApp = document.getElementById("btnCopyApp");
const btnCopyStream = document.getElementById("btnCopyStream");
const btnStart = document.getElementById("btnStart");
const btnCopyRtmp = document.getElementById("btnCopyRtmp");
const btnCopyFlv = document.getElementById("btnCopyFlv");
const btnCopyHls = document.getElementById("btnCopyHls");
const btnCopyMobilePlay = document.getElementById("btnCopyMobilePlay");
const btnQuery = document.getElementById("btnQuery");
const btnStop = document.getElementById("btnStop");
const btnStopService = document.getElementById("btnStopService");
const btnLogsRefresh = document.getElementById("btnLogsRefresh");
const elGatewayLogs = document.getElementById("gatewayLogs");
const elGatewayErrLogs = document.getElementById("gatewayErrLogs");
const elZlmLogs = document.getElementById("zlmLogs");
const elUiErrLogs = document.getElementById("uiErrLogs");
const elCopyToast = document.getElementById("copyToast");
const elMobilePlayProtocol = document.getElementById("mobilePlayProtocol");
const elMobilePlayUrl = document.getElementById("mobilePlayUrl");
const elCurrentPublishRtmp = document.getElementById("currentPublishRtmp");
const elCurrentPlayHttpFlv = document.getElementById("currentPlayHttpFlv");
const elCurrentPlayHls = document.getElementById("currentPlayHls");

let current = null;
let startupReady = false;
let serviceRunning = false;
let toastTimer = null;
const isBrowserPreview = typeof navigator !== "undefined" && !/Electron/i.test(navigator.userAgent || "");

if (elMobilePlayProtocol) {
  elMobilePlayProtocol.value = isBrowserPreview ? "hls" : "httpFlv";
}

if (window.nativeBridge?.getDefaultGatewayUrl) {
  window.nativeBridge.getDefaultGatewayUrl().then((url) => {
    if (url && typeof url === "string") {
      elGateway.value = url;
    }
  }).catch(() => {});
}

function setResult(text) {
  elResult.textContent = text;
}

function getMobilePlayUrlByProtocol(data, protocol) {
  if (!data) {
    return "";
  }
  if (protocol === "hls") {
    return data.playHls || data.playUrls?.hls || "";
  }
  return data.playHttpFlv || "";
}

function getMobileProtocolLabel(protocol) {
  return protocol === "hls" ? "HLS" : "HTTP-FLV";
}

function syncMobilePlayAddress() {
  if (!elMobilePlayUrl || !btnCopyMobilePlay) {
    return;
  }
  const protocol = elMobilePlayProtocol?.value || "httpFlv";
  const value = getMobilePlayUrlByProtocol(current, protocol);
  elMobilePlayUrl.value = value;
  btnCopyMobilePlay.disabled = !String(value || "").trim();
}

function syncStartStopButtons() {
  btnStart.disabled = !startupReady || serviceRunning;
  btnStopService.disabled = !serviceRunning;
}

function showCopyToast(message, isError = false) {
  if (!elCopyToast) {
    return;
  }
  elCopyToast.textContent = message;
  elCopyToast.className = `copy-toast show ${isError ? "error" : "success"}`;
  if (toastTimer) {
    clearTimeout(toastTimer);
  }
  toastTimer = setTimeout(() => {
    elCopyToast.className = "copy-toast";
  }, 1400);
}

async function copyTextWithFeedback(text, label) {
  const value = String(text || "").trim();
  if (!value) {
    showCopyToast(`${label}为空，无法复制`, true);
    return;
  }

  try {
    const nativeRet = window.nativeBridge?.copyText?.(value);
    if (nativeRet?.ok === true) {
      showCopyToast(`${label}已复制`);
      return;
    }
    if (navigator?.clipboard?.writeText) {
      await navigator.clipboard.writeText(value);
      showCopyToast(`${label}已复制`);
      return;
    }
    const reason = nativeRet?.message || "当前环境不支持复制";
    showCopyToast(`复制失败：${reason}`, true);
  } catch (err) {
    showCopyToast(`复制失败：${err?.message || err}`, true);
  }
}

function setStartupStatus(state, message) {
  const text = message || "状态未知";
  if (elStartupStatus) {
    elStartupStatus.textContent = text;
  }
  startupReady = state === "ready";
  syncStartStopButtons();
}

async function refreshStartupStatus() {
  if (!window.nativeBridge?.getStartupStatus) {
    setStartupStatus("ready", "当前运行模式不提供启动状态。");
    return;
  }
  try {
    const status = await window.nativeBridge.getStartupStatus();
    setStartupStatus(status?.state, status?.message || "状态未知");
  } catch (_) {
    setStartupStatus("failed", "启动状态读取失败。");
  }
}

function renderCurrent() {
  if (!current) {
    setResult("尚未创建流。");
    if (elCurrentPublishRtmp) {
      elCurrentPublishRtmp.value = "";
    }
    if (elCurrentPlayHttpFlv) {
      elCurrentPlayHttpFlv.value = "";
    }
    if (elCurrentPlayHls) {
      elCurrentPlayHls.value = "";
    }
    syncMobilePlayAddress();
    btnCopyRtmp.disabled = true;
    btnCopyFlv.disabled = true;
    btnCopyHls.disabled = true;
    btnQuery.disabled = true;
    btnStop.disabled = true;
    return;
  }
  setResult(
    [
      `ID: ${current.id}`,
      `状态: ${current.status || "running"}`,
      `服务类型: ${current.serviceMode || "httpflv"}`,
      `RTMP 推流: ${current.publishRtmp}`,
      `HTTP-FLV 播放: ${current.playHttpFlv || "未启用"}`,
      `HLS 播放: ${current.playHls || current.playUrls?.hls || "未启用"}`,
      `可拉流地址: ${JSON.stringify(current.playUrls || {}, null, 2)}`
    ].join("\n")
  );
  if (elCurrentPublishRtmp) {
    elCurrentPublishRtmp.value = current.publishRtmp || "";
  }
  if (elCurrentPlayHttpFlv) {
    elCurrentPlayHttpFlv.value = current.playHttpFlv || "";
  }
  if (elCurrentPlayHls) {
    elCurrentPlayHls.value = current.playHls || current.playUrls?.hls || "";
  }
  btnCopyRtmp.disabled = !(elCurrentPublishRtmp?.value && String(elCurrentPublishRtmp.value).trim());
  btnCopyFlv.disabled = !(elCurrentPlayHttpFlv?.value && String(elCurrentPlayHttpFlv.value).trim());
  btnCopyHls.disabled = !(elCurrentPlayHls?.value && String(elCurrentPlayHls.value).trim());
  syncMobilePlayAddress();
  btnQuery.disabled = false;
  btnStop.disabled = false;
}

async function startStream() {
  if (!startupReady) {
    await ensureServiceReady();
  }
  const base = elGateway.value.trim().replace(/\/+$/, "");
  const payload = {
    app: elApp.value.trim(),
    stream: elStream.value.trim(),
    serviceMode: elServiceMode.value,
    publisherMeta: {
      source: "electron-ui"
    }
  };
  const resp = await fetch(`${base}/api/v1/streams/start`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  });
  if (!resp.ok) {
    throw new Error(`start failed: ${resp.status}`);
  }
  current = await resp.json();
  current.status = "running";
  renderCurrent();
}

async function ensureServiceReady() {
  if (startupReady) {
    return;
  }
  if (!window.nativeBridge?.startServiceCore) {
    throw new Error("服务尚未就绪，请稍候。");
  }
  const ret = await window.nativeBridge.startServiceCore();
  if (!ret?.ok) {
    throw new Error(ret?.message || "启动服务失败");
  }
  const deadline = Date.now() + 12000;
  while (Date.now() < deadline) {
    const status = await window.nativeBridge.getStartupStatus();
    setStartupStatus(status?.state, status?.message || "状态未知");
    if (status?.state === "ready") {
      return;
    }
    if (status?.state === "failed") {
      throw new Error(status?.message || "服务启动失败");
    }
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
  throw new Error("服务启动超时，请查看日志。");
}

async function queryStatus() {
  if (!current) return;
  const base = elGateway.value.trim().replace(/\/+$/, "");
  const resp = await fetch(`${base}/api/v1/streams/${current.id}/status`);
  if (!resp.ok) {
    throw new Error(`status failed: ${resp.status}`);
  }
  current = await resp.json();
  renderCurrent();
}

async function stopStream() {
  if (!current) return;
  const base = elGateway.value.trim().replace(/\/+$/, "");
  const resp = await fetch(`${base}/api/v1/streams/${current.id}/stop`, {
    method: "POST"
  });
  if (!resp.ok) {
    throw new Error(`stop failed: ${resp.status}`);
  }
  const data = await resp.json();
  current.status = data.status || "stopped";
  renderCurrent();
}

async function refreshLogs() {
  const base = elGateway.value.trim().replace(/\/+$/, "");
  const resp = await fetch(`${base}/api/v1/debug/logs?limit=120`);
  if (!resp.ok) {
    throw new Error(`logs failed: ${resp.status}`);
  }
  const data = await resp.json();
  elGatewayLogs.value = data?.gateway?.tail || "暂无日志";
  elGatewayErrLogs.value = data?.gateway?.err || "暂无日志";
  elZlmLogs.value = data?.zlm?.tail || "暂无日志";
  elUiErrLogs.value = data?.ui?.err || "暂无日志";
}

btnStart.addEventListener("click", async () => {
  try {
    await startStream();
    serviceRunning = true;
    syncStartStopButtons();
  } catch (err) {
    setResult(`创建失败: ${err.message}`);
  }
});

btnQuery.addEventListener("click", async () => {
  try {
    await queryStatus();
  } catch (err) {
    setResult(`查询失败: ${err.message}`);
  }
});

btnStop.addEventListener("click", async () => {
  try {
    await stopStream();
  } catch (err) {
    setResult(`停止失败: ${err.message}`);
  }
});

btnCopyRtmp.addEventListener("click", () => {
  copyTextWithFeedback(elCurrentPublishRtmp?.value || "", "RTMP地址");
});

btnCopyFlv.addEventListener("click", () => {
  copyTextWithFeedback(elCurrentPlayHttpFlv?.value || "", "HTTP-FLV地址");
});

btnCopyHls.addEventListener("click", () => {
  copyTextWithFeedback(elCurrentPlayHls?.value || "", "HLS地址");
});

btnCopyMobilePlay.addEventListener("click", () => {
  const protocol = elMobilePlayProtocol?.value || "httpFlv";
  copyTextWithFeedback(elMobilePlayUrl?.value || "", `mobile拉流地址(${getMobileProtocolLabel(protocol)})`);
});

elMobilePlayProtocol?.addEventListener("change", () => {
  syncMobilePlayAddress();
});

btnCopyGateway.addEventListener("click", () => {
  copyTextWithFeedback(elGateway.value.trim(), "Gateway URL");
});

btnCopyApp.addEventListener("click", () => {
  copyTextWithFeedback(elApp.value.trim(), "App");
});

btnCopyStream.addEventListener("click", () => {
  copyTextWithFeedback(elStream.value.trim(), "Stream");
});

btnLogsRefresh.addEventListener("click", async () => {
  try {
    await refreshLogs();
  } catch (err) {
    setResult(`日志刷新失败: ${err.message}`);
  }
});

btnStopService.addEventListener("click", async () => {
  if (!window.nativeBridge?.stopServiceCore) {
    setResult("当前运行模式不支持一键停止服务。");
    return;
  }
  try {
    const ret = await window.nativeBridge.stopServiceCore();
    if (!ret?.ok) {
      setResult(`停止服务失败: ${ret?.message || "unknown"}`);
      return;
    }
    setResult("服务已停止。");
    serviceRunning = false;
    syncStartStopButtons();
    current = null;
    renderCurrent();
    refreshStartupStatus().catch(() => {});
  } catch (err) {
    setResult(`停止服务失败: ${err.message}`);
  }
});

renderCurrent();
setStartupStatus("starting", "正在启动服务...");
syncStartStopButtons();
refreshStartupStatus().catch(() => {});
setInterval(() => {
  refreshStartupStatus().catch(() => {});
}, 1200);
refreshLogs().catch(() => {});
setInterval(() => {
  refreshLogs().catch(() => {});
}, 3000);
