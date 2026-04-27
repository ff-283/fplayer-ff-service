const { contextBridge, clipboard, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("nativeBridge", {
  copyText: (text) => clipboard.writeText(String(text || "")),
  getDefaultGatewayUrl: () => ipcRenderer.invoke("service:getDefaultGatewayUrl"),
  getStartupStatus: () => ipcRenderer.invoke("service:getStartupStatus"),
  stopServiceCore: () => ipcRenderer.invoke("service:stopServiceCore"),
  stopAllAndExit: () => ipcRenderer.invoke("service:stopAllAndExit")
});
