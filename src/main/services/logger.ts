import type { Service } from './index';

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

interface LogEntry {
  timestamp: string;
  level: LogLevel;
  context: string;
  message: string;
  data?: Record<string, unknown>;
}

const SENSITIVE_PATTERNS = [
  /api[_-]?key/i,
  /password/i,
  /secret/i,
  /token/i,
  /auth/i,
  /bearer/i,
  /sk-[a-zA-Z0-9]/,
];

function sanitize(data: unknown): unknown {
  if (data === null || data === undefined) return data;
  if (typeof data === 'string') {
    for (const pattern of SENSITIVE_PATTERNS) {
      if (pattern.test(data)) {
        return '[REDACTED]';
      }
    }
    return data;
  }
  if (Array.isArray(data)) {
    return data.map(sanitize);
  }
  if (typeof data === 'object') {
    const result: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(data)) {
      const isSensitiveKey = SENSITIVE_PATTERNS.some((pattern) => pattern.test(key));
      result[key] = isSensitiveKey ? '[REDACTED]' : sanitize(value);
    }
    return result;
  }
  return data;
}

class Logger {
  private minLevel: LogLevel = 'info';
  private context: string;

  constructor(context: string) {
    this.context = context;
  }

  private shouldLog(level: LogLevel): boolean {
    const levels: LogLevel[] = ['debug', 'info', 'warn', 'error'];
    return levels.indexOf(level) >= levels.indexOf(this.minLevel);
  }

  private format(level: LogLevel, message: string, data?: Record<string, unknown>): LogEntry {
    return {
      timestamp: new Date().toISOString(),
      level,
      context: this.context,
      message,
      data: data ? (sanitize(data) as Record<string, unknown>) : undefined,
    };
  }

  private output(entry: LogEntry): void {
    const prefix = `[${entry.timestamp}] [${entry.level.toUpperCase()}] [${entry.context}]`;
    const content = `${prefix} ${entry.message}`;

    switch (entry.level) {
      case 'error':
        // eslint-disable-next-line no-console
        console.error(content, entry.data ?? '');
        break;
      case 'warn':
        // eslint-disable-next-line no-console
        console.warn(content, entry.data ?? '');
        break;
      default:
        // eslint-disable-next-line no-console
        console.log(content, entry.data ?? '');
    }
  }

  debug(message: string, data?: Record<string, unknown>): void {
    if (this.shouldLog('debug')) {
      this.output(this.format('debug', message, data));
    }
  }

  info(message: string, data?: Record<string, unknown>): void {
    if (this.shouldLog('info')) {
      this.output(this.format('info', message, data));
    }
  }

  warn(message: string, data?: Record<string, unknown>): void {
    if (this.shouldLog('warn')) {
      this.output(this.format('warn', message, data));
    }
  }

  error(message: string, data?: Record<string, unknown>): void {
    if (this.shouldLog('error')) {
      this.output(this.format('error', message, data));
    }
  }

  setMinLevel(level: LogLevel): void {
    this.minLevel = level;
  }
}

export function createLogger(context: string): Logger {
  return new Logger(context);
}

export class LoggerService implements Service {
  name = 'logger';
  private defaultLevel: LogLevel = process.env.NODE_ENV === 'development' ? 'debug' : 'info';

  async initialize(): Promise<void> {
    const logger = createLogger('LoggerService');
    logger.info('Logger initialized', { level: this.defaultLevel });
  }

  async shutdown(): Promise<void> {
    // Nothing to clean up for the logger.
  }
}
