const { contextBridge, clipboard, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("nativeBridge", {
  copyText: (text) => {
    try {
      clipboard.writeText(String(text || ""));
      return { ok: true };
    } catch (err) {
      return { ok: false, message: String(err?.message || err || "copy failed") };
    }
  },
  getDefaultGatewayUrl: () => ipcRenderer.invoke("service:getDefaultGatewayUrl"),
  getStartupStatus: () => ipcRenderer.invoke("service:getStartupStatus"),
  startServiceCore: (preferredPort) => ipcRenderer.invoke("service:startServiceCore", preferredPort),
  stopServiceCore: () => ipcRenderer.invoke("service:stopServiceCore"),
  stopAllAndExit: () => ipcRenderer.invoke("service:stopAllAndExit")
});
