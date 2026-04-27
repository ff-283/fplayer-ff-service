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
const btnQuery = document.getElementById("btnQuery");
const btnStop = document.getElementById("btnStop");
const btnStopService = document.getElementById("btnStopService");
const btnLogsRefresh = document.getElementById("btnLogsRefresh");
const elGatewayLogs = document.getElementById("gatewayLogs");
const elGatewayErrLogs = document.getElementById("gatewayErrLogs");
const elZlmLogs = document.getElementById("zlmLogs");
const elUiErrLogs = document.getElementById("uiErrLogs");

let current = null;
let startupReady = false;

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

function setStartupStatus(state, message) {
  const text = message || "状态未知";
  if (elStartupStatus) {
    elStartupStatus.textContent = text;
  }
  startupReady = state === "ready";
  btnStart.disabled = !startupReady;
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
    btnCopyRtmp.disabled = true;
    btnCopyFlv.disabled = true;
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
      `可拉流地址: ${JSON.stringify(current.playUrls || {}, null, 2)}`
    ].join("\n")
  );
  btnCopyRtmp.disabled = false;
  btnCopyFlv.disabled = false;
  btnQuery.disabled = false;
  btnStop.disabled = false;
}

async function startStream() {
  if (!startupReady) {
    throw new Error("服务尚未就绪，请稍候。");
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
  if (!current) return;
  window.nativeBridge.copyText(current.publishRtmp);
});

btnCopyFlv.addEventListener("click", () => {
  if (!current) return;
  window.nativeBridge.copyText(current.playHttpFlv);
});

btnCopyGateway.addEventListener("click", () => {
  window.nativeBridge.copyText(elGateway.value.trim());
});

btnCopyApp.addEventListener("click", () => {
  window.nativeBridge.copyText(elApp.value.trim());
});

btnCopyStream.addEventListener("click", () => {
  window.nativeBridge.copyText(elStream.value.trim());
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
    current = null;
    renderCurrent();
    refreshStartupStatus().catch(() => {});
  } catch (err) {
    setResult(`停止服务失败: ${err.message}`);
  }
});

renderCurrent();
setStartupStatus("starting", "正在启动服务...");
refreshStartupStatus().catch(() => {});
setInterval(() => {
  refreshStartupStatus().catch(() => {});
}, 1200);
refreshLogs().catch(() => {});
setInterval(() => {
  refreshLogs().catch(() => {});
}, 3000);
