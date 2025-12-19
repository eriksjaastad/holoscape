import type {
  InvokeChannel,
  InvokeRequest,
  InvokeResponse,
  EventChannel,
  EventPayload,
  ProcessMetrics,
  VisualizerState,
} from './ipc-types';

export * from './ipc-types';
export * from './errors';
export * from './security-types';

declare global {
  interface Window {
    hologram: {
      version: string;
      getMetrics: () => Promise<ProcessMetrics>;
      getApiKey: () => Promise<string | null>;
      invoke: <T extends InvokeChannel>(
        channel: T,
        ...args: InvokeRequest<T> extends void ? [] : [InvokeRequest<T>]
      ) => Promise<InvokeResponse<T>>;
      on: <T extends EventChannel>(
        channel: T,
        callback: (payload: EventPayload<T>) => void
      ) => () => void;
    };
    setVisualizerState?: (state: VisualizerState) => void;
  }
}
