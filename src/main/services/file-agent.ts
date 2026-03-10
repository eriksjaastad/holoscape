import { readFile, writeFile, rename, mkdir, readdir } from 'fs/promises';
import { existsSync, appendFileSync } from 'fs';
import { join, dirname, basename, extname, resolve } from 'path';
import { homedir } from 'os';
import { randomUUID } from 'crypto';
import { ipcMain } from 'electron';
import type { Service } from './index';
import type { LoggerService } from './logger';
import type { SecurityService } from './security';

// File operation types
export type FileOperation = 'read' | 'write' | 'move' | 'delete' | 'list';

export interface FileOperationRequest {
  operation: FileOperation;
  sourcePath: string;
  destinationPath?: string; // For move operations
  content?: string; // For write operations
  encoding?: BufferEncoding;
}

export interface FileOperationResult {
  success: boolean;
  operation: FileOperation;
  sourcePath: string;
  destinationPath?: string;
  content?: string;
  error?: string;
  auditId: string;
}

export interface FileAuditEntry {
  id: string;
  timestamp: string;
  operation: FileOperation;
  sourcePath: string;
  destinationPath?: string;
  success: boolean;
  error?: string;
  fileSize?: number;
  initiatedBy: 'user' | 'agent';
  agentId?: string;
}

// Security configuration
const DEFAULT_ALLOWED_EXTENSIONS = [
  '.txt',
  '.md',
  '.json',
  '.yaml',
  '.yml',
  '.xml',
  '.js',
  '.ts',
  '.jsx',
  '.tsx',
  '.css',
  '.html',
  '.py',
  '.rb',
  '.go',
  '.rs',
  '.java',
  '.c',
  '.cpp',
  '.h',
  '.sh',
  '.bash',
  '.zsh',
  '.log',
  '.csv',
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.svg',
  '.webp',
];

const FORBIDDEN_PATHS = [
  /^\/etc\//,
  /^\/usr\//,
  /^\/System\//,
  /^\/bin\//,
  /^\/sbin\//,
  /^\/var\//,
  /^\/private\//,
  /\.ssh/,
  /\.gnupg/,
  /\.aws/,
  /node_modules/,
  /\.git\//,
];

const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB

export class FileAgentService implements Service {
  name = 'file-agent';
  private logger!: LoggerService;
  private security!: SecurityService;
  private auditLogPath: string;
  private allowedDirectories: string[] = [];
  private allowedExtensions: string[] = DEFAULT_ALLOWED_EXTENSIONS;

  constructor() {
    // Audit log in app data directory
    this.auditLogPath = join(homedir(), '.holoscape', 'file-audit.log');
  }

  setDependencies(logger: LoggerService, security: SecurityService): void {
    this.logger = logger;
    this.security = security;
  }

  async initialize(): Promise<void> {
    // Ensure audit log directory exists
    const auditDir = dirname(this.auditLogPath);
    if (!existsSync(auditDir)) {
      await mkdir(auditDir, { recursive: true });
    }

    // Set default allowed directories
    this.allowedDirectories = [
      join(homedir(), 'Documents'),
      join(homedir(), 'Downloads'),
      join(homedir(), 'Desktop'),
      join(homedir(), '.holoscape', 'workspace'),
    ];

    // Ensure workspace exists
    const workspace = join(homedir(), '.holoscape', 'workspace');
    if (!existsSync(workspace)) {
      await mkdir(workspace, { recursive: true });
    }

    this.registerIpcHandlers();
    this.logger?.info('FileAgentService initialized', {
      allowedDirs: this.allowedDirectories.length,
    });
  }

  async shutdown(): Promise<void> {
    this.logger?.info('FileAgentService shutdown');
  }

  private registerIpcHandlers(): void {
    ipcMain.handle(
      'file-agent:execute',
      async (_, request: FileOperationRequest & { agentId?: string }) => {
        return this.execute(request, request.agentId);
      }
    );

    ipcMain.handle('file-agent:get-allowed-dirs', () => {
      return this.allowedDirectories;
    });

    ipcMain.handle('file-agent:add-allowed-dir', async (_, { dir }: { dir: string }) => {
      return this.addAllowedDirectory(dir);
    });

    ipcMain.handle('file-agent:get-audit-log', async (_, { limit }: { limit?: number }) => {
      return this.getAuditLog(limit);
    });
  }

  /**
   * Execute a file operation through the security layer
   */
  async execute(request: FileOperationRequest, agentId?: string): Promise<FileOperationResult> {
    const auditId = randomUUID();

    // Validate paths before security check
    const pathValidation = this.validatePaths(request);
    if (!pathValidation.valid) {
      const result: FileOperationResult = {
        success: false,
        operation: request.operation,
        sourcePath: request.sourcePath,
        error: pathValidation.error,
        auditId,
      };
      await this.logAudit({
        id: auditId,
        timestamp: new Date().toISOString(),
        operation: request.operation,
        sourcePath: this.sanitizePath(request.sourcePath),
        success: false,
        error: pathValidation.error,
        initiatedBy: agentId ? 'agent' : 'user',
        agentId,
      });
      return result;
    }

    // Determine action type and risk level
    const actionType = this.getSecurityActionType(request.operation);

    // Execute through security layer
    const securityResult = await this.security.executeSecured(
      actionType,
      `${request.operation} file: ${basename(request.sourcePath)}`,
      {
        path: request.sourcePath,
        userInitiated: !agentId,
      },
      async () => this.executeOperation(request)
    );

    const success = securityResult.success && !!securityResult.result;
    const result: FileOperationResult = {
      success,
      operation: request.operation,
      sourcePath: request.sourcePath,
      destinationPath: request.destinationPath,
      content: request.operation === 'read' ? securityResult.result : undefined,
      error: securityResult.error,
      auditId,
    };

    // Log to audit
    await this.logAudit({
      id: auditId,
      timestamp: new Date().toISOString(),
      operation: request.operation,
      sourcePath: this.sanitizePath(request.sourcePath),
      destinationPath: request.destinationPath
        ? this.sanitizePath(request.destinationPath)
        : undefined,
      success,
      error: securityResult.error,
      initiatedBy: agentId ? 'agent' : 'user',
      agentId,
    });

    return result;
  }

  private async executeOperation(request: FileOperationRequest): Promise<string> {
    const { operation, sourcePath, destinationPath, content, encoding = 'utf-8' } = request;

    switch (operation) {
      case 'read': {
        const data = await readFile(sourcePath, encoding);
        return data;
      }

      case 'write': {
        if (!content) throw new Error('Content required for write operation');

        // Check file size
        if (Buffer.byteLength(content, encoding) > MAX_FILE_SIZE) {
          throw new Error(`File size exceeds maximum allowed (${MAX_FILE_SIZE / 1024 / 1024}MB)`);
        }

        // Ensure directory exists
        const dir = dirname(sourcePath);
        if (!existsSync(dir)) {
          await mkdir(dir, { recursive: true });
        }

        await writeFile(sourcePath, content, encoding);
        return 'File written successfully';
      }

      case 'move': {
        if (!destinationPath) throw new Error('Destination required for move operation');

        // Move-not-modify: use rename for atomic move
        const destDir = dirname(destinationPath);
        if (!existsSync(destDir)) {
          await mkdir(destDir, { recursive: true });
        }

        await rename(sourcePath, destinationPath);

        // Handle companion files (e.g., .png + .yaml)
        await this.moveCompanionFiles(sourcePath, destinationPath);

        return 'File moved successfully';
      }

      case 'delete': {
        // Move to trash directory instead of hard delete
        const trashDir = join(homedir(), '.holoscape', 'trash');
        if (!existsSync(trashDir)) {
          await mkdir(trashDir, { recursive: true });
        }

        const trashPath = join(trashDir, `${Date.now()}_${basename(sourcePath)}`);
        await rename(sourcePath, trashPath);

        return `File moved to trash: ${trashPath}`;
      }

      case 'list': {
        const entries = await readdir(sourcePath, { withFileTypes: true });
        const files = entries.map((e) => ({
          name: e.name,
          isDirectory: e.isDirectory(),
          path: join(sourcePath, e.name),
        }));
        return JSON.stringify(files);
      }

      default:
        throw new Error(`Unknown operation: ${operation}`);
    }
  }

  /**
   * Move companion files (e.g., if moving skin.png, also move skin.yaml)
   */
  private async moveCompanionFiles(sourcePath: string, destinationPath: string): Promise<void> {
    const sourceBase = sourcePath.replace(extname(sourcePath), '');
    const destBase = destinationPath.replace(extname(destinationPath), '');

    const companionExtensions = ['.yaml', '.yml', '.json', '.meta', '.md'];

    for (const ext of companionExtensions) {
      const companionSource = sourceBase + ext;
      const companionDest = destBase + ext;

      if (existsSync(companionSource)) {
        try {
          await rename(companionSource, companionDest);
          this.logger?.debug('Moved companion file', {
            from: basename(companionSource),
            to: basename(companionDest),
          });
        } catch (error) {
          this.logger?.warn('Failed to move companion file', {
            file: basename(companionSource),
            error: error instanceof Error ? error.message : 'Unknown',
          });
        }
      }
    }
  }

  private validatePaths(request: FileOperationRequest): { valid: boolean; error?: string } {
    const { operation, sourcePath, destinationPath } = request;

    // Resolve to absolute path
    const absSource = resolve(sourcePath);

    // Check forbidden paths
    for (const pattern of FORBIDDEN_PATHS) {
      if (pattern.test(absSource)) {
        return {
          valid: false,
          error: `Access denied: ${basename(absSource)} is in a protected location`,
        };
      }
    }

    // Check allowed directories for write operations
    if (operation !== 'read') {
      const inAllowed = this.allowedDirectories.some((dir) => absSource.startsWith(resolve(dir)));

      if (!inAllowed) {
        return {
          valid: false,
          error: `Write access denied: ${basename(absSource)} is outside allowed directories`,
        };
      }
    }

    // Check file extension
    const ext = extname(absSource).toLowerCase();
    if (ext && !this.allowedExtensions.includes(ext)) {
      return {
        valid: false,
        error: `File type not allowed: ${ext}`,
      };
    }

    // Validate destination for move
    if (destinationPath) {
      const absDest = resolve(destinationPath);

      for (const pattern of FORBIDDEN_PATHS) {
        if (pattern.test(absDest)) {
          return { valid: false, error: `Destination is in a protected location` };
        }
      }

      const destInAllowed = this.allowedDirectories.some((dir) => absDest.startsWith(resolve(dir)));

      if (!destInAllowed) {
        return {
          valid: false,
          error: `Destination is outside allowed directories`,
        };
      }
    }

    return { valid: true };
  }

  private getSecurityActionType(operation: FileOperation): string {
    switch (operation) {
      case 'read':
        return 'file:read';
      case 'write':
        return 'file:write';
      case 'move':
        return 'file:write'; // Move is a write operation
      case 'delete':
        return 'file:delete';
      case 'list':
        return 'file:list';
      default:
        return 'file:write';
    }
  }

  /**
   * Sanitize path for audit log (remove home directory prefix)
   */
  private sanitizePath(filePath: string): string {
    const home = homedir();
    if (filePath.startsWith(home)) {
      return '~' + filePath.slice(home.length);
    }
    return filePath;
  }

  private async logAudit(entry: FileAuditEntry): Promise<void> {
    try {
      const line = JSON.stringify(entry) + '\n';
      appendFileSync(this.auditLogPath, line);
    } catch (error) {
      this.logger?.error('Failed to write audit log', {
        error: error instanceof Error ? error.message : 'Unknown',
      });
    }
  }

  /**
   * Get recent audit log entries
   */
  async getAuditLog(limit = 100): Promise<FileAuditEntry[]> {
    try {
      if (!existsSync(this.auditLogPath)) {
        return [];
      }

      const content = await readFile(this.auditLogPath, 'utf-8');
      const lines = content.trim().split('\n').filter(Boolean);
      const entries = lines
        .slice(-limit)
        .map((line) => {
          try {
            return JSON.parse(line) as FileAuditEntry;
          } catch {
            return null;
          }
        })
        .filter((e): e is FileAuditEntry => e !== null);

      return entries.reverse(); // Most recent first
    } catch {
      return [];
    }
  }

  /**
   * Add a directory to the allowed list
   */
  addAllowedDirectory(dir: string): boolean {
    const absDir = resolve(dir);

    // Don't allow adding forbidden paths
    for (const pattern of FORBIDDEN_PATHS) {
      if (pattern.test(absDir)) {
        return false;
      }
    }

    if (!this.allowedDirectories.includes(absDir)) {
      this.allowedDirectories.push(absDir);
      this.logger?.info('Added allowed directory', { dir: this.sanitizePath(absDir) });
      return true;
    }

    return false;
  }

  /**
   * Add allowed extensions
   */
  addAllowedExtension(ext: string): void {
    const normalizedExt = ext.startsWith('.') ? ext.toLowerCase() : `.${ext.toLowerCase()}`;
    if (!this.allowedExtensions.includes(normalizedExt)) {
      this.allowedExtensions.push(normalizedExt);
    }
  }
}
