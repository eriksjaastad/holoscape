import { describe, it, expect } from 'vitest';
import { AppError, toErrorCode, isNetworkError, isAuthError, isRateLimitError } from './errors';

describe('AppError', () => {
  it('creates error with code and message', () => {
    const error = new AppError('API_TIMEOUT', 'Request timed out');
    expect(error.code).toBe('API_TIMEOUT');
    expect(error.message).toBe('Request timed out');
    expect(error.isOperational).toBe(true);
  });

  it('converts unknown errors', () => {
    const original = new Error('Something broke');
    const appError = AppError.fromUnknown(original);
    expect(appError.code).toBe('UNKNOWN');
    expect(appError.message).toBe('Something broke');
  });

  it('passes through existing AppErrors', () => {
    const original = new AppError('API_AUTH_FAILED', 'Bad key');
    const result = AppError.fromUnknown(original);
    expect(result).toBe(original);
  });
});

describe('toErrorCode', () => {
  it('detects network errors', () => {
    expect(toErrorCode(new Error('ENOTFOUND'))).toBe('NETWORK_OFFLINE');
  });

  it('detects auth errors', () => {
    expect(toErrorCode(new Error('401 unauthorized'))).toBe('API_AUTH_FAILED');
  });

  it('detects rate limit errors', () => {
    expect(toErrorCode(new Error('429 rate limit exceeded'))).toBe('API_RATE_LIMITED');
  });

  it('returns UNKNOWN for unrecognized errors', () => {
    expect(toErrorCode(new Error('random error'))).toBe('UNKNOWN');
  });
});

describe('error type guards', () => {
  it('isNetworkError identifies network issues', () => {
    expect(isNetworkError(new Error('ECONNREFUSED'))).toBe(true);
    expect(isNetworkError(new Error('random'))).toBe(false);
  });

  it('isAuthError identifies auth issues', () => {
    expect(isAuthError(new Error('invalid_api_key'))).toBe(true);
    expect(isAuthError(new Error('random'))).toBe(false);
  });

  it('isRateLimitError identifies rate limits', () => {
    expect(isRateLimitError(new Error('rate limit'))).toBe(true);
    expect(isRateLimitError(new Error('random'))).toBe(false);
  });
});
