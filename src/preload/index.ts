import { contextBridge, ipcRenderer } from 'electron';
import type {
  InvokeChannel,
  InvokeRequest,
  InvokeResponse,
  EventChannel,
  EventPayload,
  ProcessMetrics,
} from '@shared/ipc-types';

async function invoke<T extends InvokeChannel>(
  channel: T,
  ...args: InvokeRequest<T> extends void ? [] : [InvokeRequest<T>]
): Promise<InvokeResponse<T>> {
  return ipcRenderer.invoke(channel, ...(args as [InvokeRequest<T>]));
}

function on<T extends EventChannel>(
  channel: T,
  callback: (payload: EventPayload<T>) => void
): () => void {
  const handler = (_event: Electron.IpcRendererEvent, payload: EventPayload<T>) => {
    callback(payload);
  };
  ipcRenderer.on(channel, handler);

  return () => ipcRenderer.removeListener(channel, handler);
}

export interface HologramAPI {
  version: string;
  getMetrics: () => Promise<ProcessMetrics>;
  getApiKey: () => Promise<string | null>;
  invoke: typeof invoke;
  on: typeof on;
}

const api: HologramAPI = {
  version: '0.1.0-alpha',
  getMetrics: () => invoke('get-process-metrics'),
  getApiKey: () => invoke('get-api-key'),
  invoke,
  on,
};

contextBridge.exposeInMainWorld('hologram', api);
