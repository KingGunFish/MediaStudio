// src/preload/preload.ts
import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('electronAPI', {
  openFile: (filters?: string) => ipcRenderer.invoke('dialog:openFile', filters),
  saveFile: (defaultName?: string) => ipcRenderer.invoke('dialog:saveFile', defaultName),
  revealInFolder: (p: string) => ipcRenderer.invoke('shell:reveal', p),
  sdkInit: () => ipcRenderer.invoke('sdk:init'),
  probeVideo: (input: string) => ipcRenderer.invoke('sdk:probe', input),
  videoToGif: (input: string, output: string, options: any, pid: string) =>
    ipcRenderer.invoke('sdk:video2gif', { input, output, options }, pid),
  keying: (input: string, output: string, options: any, pid: string) =>
    ipcRenderer.invoke('sdk:keying', { input, output, options }, pid),
  onProgress: (pid: string, cb: (data: any) => void) => {
    const h = (_: any, d: any) => cb(d);
    ipcRenderer.on(`progress:${pid}`, h);
    return () => ipcRenderer.off(`progress:${pid}`, h);
  },
  onDone: (pid: string, cb: (result: any) => void) => {
    const h = (_: any, d: any) => cb(d);
    ipcRenderer.on(`done:${pid}`, h);
    return () => ipcRenderer.off(`done:${pid}`, h);
  },
});