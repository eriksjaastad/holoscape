export interface Service {
  name: string;
  initialize(): Promise<void>;
  shutdown(): Promise<void>;
}

class ServiceRegistry {
  private services: Map<string, Service> = new Map();
  private initialized = false;

  register(service: Service): void {
    if (this.initialized) {
      throw new Error(`Cannot register service "${service.name}" after initialization`);
    }
    if (this.services.has(service.name)) {
      throw new Error(`Service "${service.name}" already registered`);
    }
    this.services.set(service.name, service);
  }

  async initializeAll(): Promise<void> {
    if (this.initialized) return;

    for (const [name, service] of this.services) {
      try {
        await service.initialize();
        // eslint-disable-next-line no-console
        console.log(`[ServiceRegistry] Initialized: ${name}`);
      } catch (error) {
        // eslint-disable-next-line no-console
        console.error(`[ServiceRegistry] Failed to initialize: ${name}`, error);
        throw error;
      }
    }

    this.initialized = true;
  }

  async shutdownAll(): Promise<void> {
    for (const [name, service] of this.services) {
      try {
        await service.shutdown();
        // eslint-disable-next-line no-console
        console.log(`[ServiceRegistry] Shutdown: ${name}`);
      } catch (error) {
        // eslint-disable-next-line no-console
        console.error(`[ServiceRegistry] Failed to shutdown: ${name}`, error);
      }
    }
    this.services.clear();
    this.initialized = false;
  }

  get<T extends Service>(name: string): T | undefined {
    return this.services.get(name) as T | undefined;
  }
}

export const registry = new ServiceRegistry();
