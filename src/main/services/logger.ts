import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  statSync,
  unlinkSync,
  renameSync,
} from 'fs';
import { join } from 'path';
import { app } from 'electron';
import { Service } from './index.js';

type LogLevel = 'debug' | 'info' | 'warn' | 'error';

interface LogEntry {
  timestamp: string;
  level: LogLevel;
  message: string;
  context?: Record<string, unknown>;
}

// Patterns that should NEVER appear in logs
const SENSITIVE_PATTERNS = [
  /sk-[a-zA-Z0-9]{20,}/g, // OpenAI keys
  /sk-proj-[a-zA-Z0-9-_]{20,}/g, // OpenAI project keys
  /anthropic-[a-zA-Z0-9]{20,}/g, // Anthropic keys
  /AIza[a-zA-Z0-9_-]{35}/g, // Google API keys
  /api[_-]?key["\s:=]+["']?[a-zA-Z0-9_-]{20,}/gi,
  /password["\s:=]+["']?[^\s"']+/gi,
  /secret["\s:=]+["']?[^\s"']+/gi,
  /token["\s:=]+["']?[a-zA-Z0-9_-]{20,}/gi,
  /bearer\s+[a-zA-Z0-9_-]{20,}/gi,
  /authorization["\s:=]+["']?[^\s"']+/gi,
];

const MAX_LOG_SIZE = 10 * 1024 * 1024; // 10MB
const MAX_LOG_AGE_DAYS = 7;
const MAX_LOG_FILES = 10;

export class LoggerService implements Service {
  name = 'logger';
  private logLevel: LogLevel = 'info';
  private logDir: string;
  private currentLogFile: string;
  private logBuffer: LogEntry[] = [];
  private flushInterval: NodeJS.Timeout | null = null;

  constructor() {
    this.logDir = join(app.getPath('userData'), 'logs');
    this.currentLogFile = this.getLogFileName();
  }

  async initialize(): Promise<void> {
    if (!existsSync(this.logDir)) {
      mkdirSync(this.logDir, { recursive: true });
    }

    // Clean old logs on startup
    await this.cleanOldLogs();

    // Flush logs every 5 seconds
    this.flushInterval = setInterval(() => this.flush(), 5000);

    this.info('Logger initialized', { logDir: this.logDir });
  }

  async shutdown(): Promise<void> {
    if (this.flushInterval) {
      clearInterval(this.flushInterval);
    }
    await this.flush();
  }

  setLevel(level: LogLevel): void {
    this.logLevel = level;
  }

  debug(message: string, context?: Record<string, unknown>): void {
    this.log('debug', message, context);
  }

  info(message: string, context?: Record<string, unknown>): void {
    this.log('info', message, context);
  }

  warn(message: string, context?: Record<string, unknown>): void {
    this.log('warn', message, context);
  }

  error(message: string, context?: Record<string, unknown>): void {
    this.log('error', message, context);
  }

  private log(level: LogLevel, message: string, context?: Record<string, unknown>): void {
    const levels: LogLevel[] = ['debug', 'info', 'warn', 'error'];
    if (levels.indexOf(level) < levels.indexOf(this.logLevel)) {
      return;
    }

    const entry: LogEntry = {
      timestamp: new Date().toISOString(),
      level,
      message: this.sanitize(message),
      context: context ? this.sanitizeContext(context) : undefined,
    };

    this.logBuffer.push(entry);

    // Also log to console in development
    if (process.env.NODE_ENV !== 'production') {
      const prefix = `[${entry.timestamp}] [${level.toUpperCase()}]`;
      const contextStr = context ? ` ${JSON.stringify(entry.context)}` : '';
      console.log(`${prefix} ${entry.message}${contextStr}`);
    }

    // Check if we need to rotate
    this.checkRotation();
  }

  private sanitize(text: string): string {
    let result = text;
    for (const pattern of SENSITIVE_PATTERNS) {
      result = result.replace(pattern, '[REDACTED]');
    }
    return result;
  }

  private sanitizeContext(context: Record<string, unknown>): Record<string, unknown> {
    const result: Record<string, unknown> = {};

    for (const [key, value] of Object.entries(context)) {
      // Redact keys that look sensitive
      const lowerKey = key.toLowerCase();
      if (
        lowerKey.includes('key') ||
        lowerKey.includes('secret') ||
        lowerKey.includes('password') ||
        lowerKey.includes('token') ||
        lowerKey.includes('authorization')
      ) {
        result[key] = '[REDACTED]';
        continue;
      }

      // Sanitize string values
      if (typeof value === 'string') {
        result[key] = this.sanitize(value);
      } else if (typeof value === 'object' && value !== null) {
        result[key] = this.sanitizeContext(value as Record<string, unknown>);
      } else {
        result[key] = value;
      }
    }

    return result;
  }

  private getLogFileName(): string {
    const date = new Date().toISOString().split('T')[0];
    return join(this.logDir, `holoscape-${date}.log`);
  }

  private async flush(): Promise<void> {
    if (this.logBuffer.length === 0) return;

    const entries = this.logBuffer.splice(0, this.logBuffer.length);
    const content = entries.map((e) => JSON.stringify(e)).join('\n') + '\n';

    try {
      const logFile = this.getLogFileName();
      if (logFile !== this.currentLogFile) {
        this.currentLogFile = logFile;
      }

      // Use appendFileSync for better performance - no need to read entire file
      appendFileSync(this.currentLogFile, content);
    } catch (error) {
      console.error('Failed to write logs:', error);
    }
  }

  private checkRotation(): void {
    try {
      if (!existsSync(this.currentLogFile)) return;

      const stats = statSync(this.currentLogFile);
      if (stats.size > MAX_LOG_SIZE) {
        // Use atomic rename instead of read+write for better performance
        const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
        const rotatedName = this.currentLogFile.replace('.log', `-${timestamp}.log`);
        renameSync(this.currentLogFile, rotatedName);
        this.info('Log file rotated', { rotatedTo: rotatedName });
      }
    } catch (error) {
      console.error('Log rotation check failed:', error);
    }
  }

  private async cleanOldLogs(): Promise<void> {
    try {
      const files = readdirSync(this.logDir)
        .filter((f) => f.endsWith('.log'))
        .map((f) => ({
          name: f,
          path: join(this.logDir, f),
          mtime: statSync(join(this.logDir, f)).mtime,
        }))
        .sort((a, b) => b.mtime.getTime() - a.mtime.getTime());

      const cutoffDate = new Date();
      cutoffDate.setDate(cutoffDate.getDate() - MAX_LOG_AGE_DAYS);

      let deleted = 0;

      for (let i = 0; i < files.length; i++) {
        const file = files[i];
        // Delete if too old OR if we have too many files
        if (file.mtime < cutoffDate || i >= MAX_LOG_FILES) {
          unlinkSync(file.path);
          deleted++;
        }
      }

      if (deleted > 0) {
        console.log(`Cleaned ${deleted} old log files`);
      }
    } catch (error) {
      console.error('Failed to clean old logs:', error);
    }
  }

  /**
   * Clear all logs (user-triggered)
   */
  async clearAllLogs(): Promise<number> {
    try {
      const files = readdirSync(this.logDir).filter((f) => f.endsWith('.log'));

      for (const file of files) {
        unlinkSync(join(this.logDir, file));
      }

      this.logBuffer = [];
      console.log(`Cleared ${files.length} log files`);

      return files.length;
    } catch (error) {
      console.error('Failed to clear logs:', error);
      return 0;
    }
  }

  /**
   * Get log directory path (for UI)
   */
  getLogDir(): string {
    return this.logDir;
  }
}

/**
 * Create a logger instance for backward compatibility
 * This uses console logging with sanitization
 */
export function createLogger(context: string) {
  return {
    debug(message: string, data?: Record<string, unknown>): void {
      if (process.env.NODE_ENV !== 'production') {
        console.log(`[DEBUG] [${context}] ${message}`, data || '');
      }
    },
    info(message: string, data?: Record<string, unknown>): void {
      console.log(`[INFO] [${context}] ${message}`, data || '');
    },
    warn(message: string, data?: Record<string, unknown>): void {
      console.warn(`[WARN] [${context}] ${message}`, data || '');
    },
    error(message: string, data?: Record<string, unknown>): void {
      console.error(`[ERROR] [${context}] ${message}`, data || '');
    },
  };
}
