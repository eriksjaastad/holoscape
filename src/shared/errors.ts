import type { ErrorCode } from './ipc-types';

export class AppError extends Error {
  readonly code: ErrorCode;
  readonly isOperational: boolean;
  readonly context?: Record<string, unknown>;

  constructor(
    code: ErrorCode,
    message: string,
    options?: {
      cause?: Error;
      isOperational?: boolean;
      context?: Record<string, unknown>;
    }
  ) {
    super(message, { cause: options?.cause });
    this.name = 'AppError';
    this.code = code;
    this.isOperational = options?.isOperational ?? true;
    this.context = options?.context;
  }

  static fromUnknown(error: unknown): AppError {
    if (error instanceof AppError) return error;

    if (error instanceof Error) {
      return new AppError('UNKNOWN', error.message, { cause: error });
    }

    return new AppError('UNKNOWN', String(error));
  }

  toJSON(): Record<string, unknown> {
    return {
      name: this.name,
      code: this.code,
      message: this.message,
      isOperational: this.isOperational,
      context: this.context,
    };
  }
}

export function isNetworkError(error: unknown): boolean {
  if (error instanceof AppError) {
    return error.code === 'NETWORK_OFFLINE';
  }
  if (error instanceof Error) {
    return (
      error.message.includes('network') ||
      error.message.includes('ENOTFOUND') ||
      error.message.includes('ECONNREFUSED')
    );
  }
  return false;
}

export function isAuthError(error: unknown): boolean {
  if (error instanceof AppError) {
    return error.code === 'API_AUTH_FAILED';
  }
  if (error instanceof Error) {
    return (
      error.message.includes('401') ||
      error.message.toLowerCase().includes('unauthorized') ||
      error.message.includes('invalid_api_key')
    );
  }
  return false;
}

export function isRateLimitError(error: unknown): boolean {
  if (error instanceof AppError) {
    return error.code === 'API_RATE_LIMITED';
  }
  if (error instanceof Error) {
    return error.message.includes('429') || error.message.includes('rate limit');
  }
  return false;
}

export function toErrorCode(error: unknown): ErrorCode {
  if (isNetworkError(error)) return 'NETWORK_OFFLINE';
  if (isAuthError(error)) return 'API_AUTH_FAILED';
  if (isRateLimitError(error)) return 'API_RATE_LIMITED';
  if (error instanceof AppError) {
    return error.code;
  }
  return 'UNKNOWN';
}
