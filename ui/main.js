const { app, BrowserWindow, ipcMain } = require("electron");
const fs = require("fs");
const http = require("http");
const net = require("net");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

const managedMode = process.env.SERVICE_MANAGED_MODE === "1" || app.isPackaged;
let stopTriggered = false;
let managedChildren = { zlm: null, gateway: null };
let coreStartupStatus = {
  state: "idle",
  message: "未启动"
};

function getServiceRootDir() {
  if (app.isPackaged) {
    const exeDir = path.dirname(process.execPath);
    const siblingLayoutReady = [
      path.join(exeDir, "3rd"),
      path.join(exeDir, "gateway"),
      path.join(exeDir, "scripts")
    ].every((p) => fs.existsSync(p));
    return siblingLayoutReady ? exeDir : process.resourcesPath;
  }
  return path.resolve(__dirname, "..");
}

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function getManagedPaths() {
  const rootDir = getServiceRootDir();
  const runDir = path.join(rootDir, "run");
  const logDir = path.join(rootDir, "logs");
  ensureDir(runDir);
  ensureDir(logDir);
  return { rootDir, runDir, logDir };
}

function getLanIpv4() {
  const interfaces = os.networkInterfaces();
  for (const name of Object.keys(interfaces)) {
    const list = interfaces[name] || [];
    for (const item of list) {
      if (!item || item.family !== "IPv4" || item.internal) {
        continue;
      }
      if (typeof item.address === "string" && item.address && !item.address.startsWith("169.254.")) {
        return item.address;
      }
    }
  }
  return "127.0.0.1";
}

function writePidFile(runDir, name, pid) {
  fs.writeFileSync(path.join(runDir, `${name}.pid`), `${pid}\n`, "utf8");
}

function removeFileIfExists(filePath) {
  try {
    if (fs.existsSync(filePath)) {
      fs.unlinkSync(filePath);
    }
  } catch (_) {
  }
}

function openLogFds(logDir, baseName) {
  const logPath = path.join(logDir, `${baseName}.log`);
  const errPath = path.join(logDir, `${baseName}.err.log`);
  const outFd = fs.openSync(logPath, "a");
  const errFd = fs.openSync(errPath, "a");
  return { outFd, errFd };
}

function spawnWithLogs(command, args, options, logDir, baseName) {
  const { outFd, errFd } = openLogFds(logDir, baseName);
  return spawn(command, args, {
    ...options,
    windowsHide: true,
    stdio: ["ignore", outFd, errFd]
  });
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function httpGetJson(url, timeoutMs = 1000) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, { timeout: timeoutMs }, (res) => {
      const chunks = [];
      res.on("data", (d) => chunks.push(d));
      res.on("end", () => {
        const body = Buffer.concat(chunks).toString("utf8");
        resolve({ statusCode: res.statusCode || 0, body });
      });
    });
    req.on("timeout", () => {
      req.destroy(new Error("timeout"));
    });
    req.on("error", reject);
  });
}

async function waitGatewayHealthy(port, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const resp = await httpGetJson(`http://127.0.0.1:${port}/healthz`);
      if (resp.statusCode === 200 && resp.body.includes("ok")) {
        return true;
      }
    } catch (_) {
    }
    await sleep(200);
  }
  return false;
}

function getFreePort(preferredPort = 0) {
  return new Promise((resolve) => {
    const tryPort = (port) => {
      const server = net.createServer();
      server.unref();
      server.on("error", () => {
        resolve(0);
      });
      server.listen(port, "127.0.0.1", () => {
        const addr = server.address();
        const selected = typeof addr === "object" && addr ? addr.port : 0;
        server.close(() => resolve(selected));
      });
    };
    if (preferredPort > 0) {
      tryPort(preferredPort);
    } else {
      tryPort(0);
    }
  });
}

function updateZlmConfig(templatePath, targetPath, ports) {
  const content = fs.readFileSync(templatePath, "utf8");
  const lines = content.split(/\r?\n/);
  const patchKey = (section, key, value) => {
    let inSection = false;
    for (let i = 0; i < lines.length; i += 1) {
      const line = lines[i];
      const sectionMatch = line.match(/^\s*\[(.+)\]\s*$/);
      if (sectionMatch) {
        inSection = sectionMatch[1] === section;
        continue;
      }
      if (inSection && new RegExp(`^\\s*${key}\\s*=`).test(line)) {
        lines[i] = `${key}=${value}`;
        return;
      }
    }
  };
  patchKey("http", "port", ports.httpPort);
  patchKey("http", "sslport", ports.httpsPort);
  patchKey("rtmp", "port", ports.rtmpPort);
  fs.writeFileSync(targetPath, lines.join("\n"), "utf8");
}

function safeKillPid(pid) {
  if (!pid || pid <= 0 || pid === process.pid) {
    return;
  }
  try {
    process.kill(pid);
  } catch (_) {
  }
}

function stopManagedCoreInternal() {
  const { runDir } = getManagedPaths();

  if (managedChildren.gateway && managedChildren.gateway.pid) {
    safeKillPid(managedChildren.gateway.pid);
  }
  if (managedChildren.zlm && managedChildren.zlm.pid) {
    safeKillPid(managedChildren.zlm.pid);
  }
  managedChildren = { zlm: null, gateway: null };

  ["gateway.pid", "zlm.pid", "ui.pid", "runtime.json"].forEach((name) => {
    removeFileIfExists(path.join(runDir, name));
  });
}

async function startManagedCoreInternal() {
  coreStartupStatus = { state: "starting", message: "正在启动 ZLM 与 gateway..." };
  const { rootDir, runDir, logDir } = getManagedPaths();
  const zlmDir = path.join(rootDir, "3rd", "zlm", "windows");
  const zlmExe = path.join(zlmDir, "MediaServer.exe");
  const zlmCfg = path.join(zlmDir, "config.ini");
  const zlmRuntimeCfg = path.join(runDir, "zlm.runtime.ini");
  const gatewayDir = path.join(rootDir, "gateway");
  const gatewayExe = path.join(gatewayDir, "bin", "gateway.exe");

  if (!fs.existsSync(zlmExe) || !fs.existsSync(zlmCfg)) {
    throw new Error("ZLM runtime files are missing.");
  }
  if (!fs.existsSync(gatewayExe)) {
    throw new Error("gateway/bin/gateway.exe is missing.");
  }

  const rtmpPort = (await getFreePort(1935)) || (await getFreePort(0));
  const httpPort = (await getFreePort(8080)) || (await getFreePort(0));
  const httpsPort = (await getFreePort(8443)) || (await getFreePort(0));
  updateZlmConfig(zlmCfg, zlmRuntimeCfg, { rtmpPort, httpPort, httpsPort });

  const zlm = spawnWithLogs(
    zlmExe,
    ["-c", zlmRuntimeCfg],
    { cwd: zlmDir, detached: false },
    logDir,
    "zlm"
  );
  managedChildren.zlm = zlm;
  writePidFile(runDir, "zlm", zlm.pid);

  let gatewayPort = -1;
  let gateway = null;
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const preferred = attempt === 0 ? 9000 : 0;
    const candidate = (await getFreePort(preferred)) || (await getFreePort(0));
    if (!candidate) {
      continue;
    }
    gateway = spawnWithLogs(
      gatewayExe,
      [],
      {
        cwd: gatewayDir,
        detached: false,
        env: {
          ...process.env,
          ZLM_RTMP_PORT: String(rtmpPort),
          ZLM_HTTP_PORT: String(httpPort),
          SERVICE_GATEWAY_PORT: String(candidate),
          SERVICE_LOG_DIR: logDir
        }
      },
      logDir,
      "gateway"
    );
    const healthy = await waitGatewayHealthy(candidate, 5000);
    if (healthy) {
      gatewayPort = candidate;
      break;
    }
    safeKillPid(gateway.pid);
    gateway = null;
  }

  if (!gateway || gatewayPort <= 0) {
    safeKillPid(zlm.pid);
    coreStartupStatus = { state: "failed", message: "gateway 启动失败，请查看日志。" };
    throw new Error("gateway failed to start on available ports.");
  }

  managedChildren.gateway = gateway;
  writePidFile(runDir, "gateway", gateway.pid);
  writePidFile(runDir, "ui", process.pid);

  const lanHost = getLanIpv4();
  const runtime = {
    startedAt: new Date().toISOString().slice(0, 19),
    gateway: {
      host: lanHost,
      port: gatewayPort,
      url: `http://${lanHost}:${gatewayPort}`
    },
    zlm: {
      rtmpPort,
      httpPort,
      httpsPort
    },
    endpoints: {
      publishRtmp: `rtmp://127.0.0.1:${rtmpPort}/live/stream001`,
      playHttpFlv: `http://127.0.0.1:${httpPort}/live/stream001.flv`
    }
  };
  fs.writeFileSync(path.join(runDir, "runtime.json"), JSON.stringify(runtime, null, 2), "utf8");
  coreStartupStatus = { state: "ready", message: `服务已就绪（gateway: ${runtime.gateway.url}）` };
}

function startManagedCoreByScript() {
  const rootDir = getServiceRootDir();
  const scriptPath = path.join(rootDir, "scripts", "start-all.ps1");
  if (!fs.existsSync(scriptPath)) {
    return;
  }
  const child = spawn("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPath], {
    cwd: rootDir,
    detached: true,
    stdio: "ignore",
    windowsHide: true,
    env: {
      ...process.env,
      SERVICE_SKIP_UI: "1",
      SERVICE_MANAGED_MODE: "1"
    }
  });
  child.unref();
}

function stopManagedCoreByScript() {
  const rootDir = getServiceRootDir();
  const scriptPath = path.join(rootDir, "scripts", "stop-all.ps1");
  const child = spawn("powershell", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPath], {
    cwd: rootDir,
    detached: true,
    stdio: "ignore",
    windowsHide: true
  });
  child.unref();
}

function readRuntimeGatewayUrl() {
  try {
    const rootDir = getServiceRootDir();
    const runtimePath = path.join(rootDir, "run", "runtime.json");
    if (!fs.existsSync(runtimePath)) {
      return null;
    }
    const parsed = JSON.parse(fs.readFileSync(runtimePath, "utf8"));
    const url = parsed?.gateway?.url;
    return typeof url === "string" && url.trim() ? url.trim() : null;
  } catch (_) {
    return null;
  }
}

function createWindow() {
  const win = new BrowserWindow({
    width: 980,
    height: 720,
    minWidth: 860,
    minHeight: 640,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false
    }
  });
  win.loadFile(path.join(__dirname, "renderer", "index.html"));
}

ipcMain.handle("service:getDefaultGatewayUrl", async () => {
  return readRuntimeGatewayUrl() || process.env.SERVICE_GATEWAY_URL || `http://${getLanIpv4()}:9000`;
});

ipcMain.handle("service:getStartupStatus", async () => {
  if (!managedMode) {
    return { state: "ready", message: "当前为非托管模式。" };
  }
  return coreStartupStatus;
});

ipcMain.handle("service:stopAllAndExit", async () => {
  if (!managedMode) {
    return { ok: false, message: "Not running in managed mode." };
  }
  if (stopTriggered) {
    return { ok: true };
  }
  stopTriggered = true;
  if (app.isPackaged) {
    stopManagedCoreInternal();
  } else {
    stopManagedCoreByScript();
  }
  setTimeout(() => app.quit(), 200);
  return { ok: true };
});

ipcMain.handle("service:stopServiceCore", async () => {
  if (!managedMode) {
    return { ok: false, message: "Not running in managed mode." };
  }
  if (app.isPackaged) {
    stopManagedCoreInternal();
  } else {
    stopManagedCoreByScript();
  }
  coreStartupStatus = { state: "stopped", message: "服务已停止（窗口仍保持打开）" };
  return { ok: true };
});

app.whenReady().then(() => {
  coreStartupStatus = managedMode
    ? { state: "starting", message: "正在初始化服务..." }
    : { state: "ready", message: "当前为非托管模式。" };
  createWindow();
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });

  // Start service core in background to keep UI startup fast.
  if (managedMode) {
    (async () => {
      try {
        if (app.isPackaged) {
          await startManagedCoreInternal();
        } else {
          startManagedCoreByScript();
        }
      } catch (err) {
        // Keep UI alive for debugging; logs record service startup failures.
        coreStartupStatus = { state: "failed", message: `启动失败：${err?.message || err}` };
        console.error(`Managed core startup failed: ${err?.message || err}`);
      }
    })();
  }
});

app.on("window-all-closed", () => {
  if (managedMode && !stopTriggered) {
    stopTriggered = true;
    if (app.isPackaged) {
      stopManagedCoreInternal();
    } else {
      stopManagedCoreByScript();
    }
  }
  if (process.platform !== "darwin") {
    app.quit();
  }
});
