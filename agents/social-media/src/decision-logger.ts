import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { join } from 'path';
import { randomUUID } from 'crypto';
import type { Decision, PostPackage } from './types.js';

const DATA_DIR = join(process.cwd(), 'data');
const DECISIONS_FILE = join(DATA_DIR, 'decisions.json');
const PACKAGES_FILE = join(DATA_DIR, 'packages.json');

function ensureDataDir(): void {
  if (!existsSync(DATA_DIR)) {
    mkdirSync(DATA_DIR, { recursive: true });
  }
}

function loadDecisions(): Decision[] {
  ensureDataDir();
  if (!existsSync(DECISIONS_FILE)) {
    return [];
  }
  return JSON.parse(readFileSync(DECISIONS_FILE, 'utf-8'));
}

function saveDecisions(decisions: Decision[]): void {
  ensureDataDir();
  writeFileSync(DECISIONS_FILE, JSON.stringify(decisions, null, 2));
}

function loadPackages(): PostPackage[] {
  ensureDataDir();
  if (!existsSync(PACKAGES_FILE)) {
    return [];
  }
  return JSON.parse(readFileSync(PACKAGES_FILE, 'utf-8'));
}

function savePackages(packages: PostPackage[]): void {
  ensureDataDir();
  writeFileSync(PACKAGES_FILE, JSON.stringify(packages, null, 2));
}

export function logDecision(
  packageId: string,
  action: Decision['action'],
  reason?: string,
  metadata?: Record<string, unknown>
): Decision {
  const decision: Decision = {
    id: randomUUID(),
    packageId,
    action,
    timestamp: new Date().toISOString(),
    reason,
    metadata,
  };

  const decisions = loadDecisions();
  decisions.push(decision);
  saveDecisions(decisions);

  console.log(`📋 Decision logged: ${action} for package ${packageId.slice(0, 8)}...`);
  return decision;
}

export function savePackage(pkg: PostPackage): void {
  const packages = loadPackages();
  const existingIndex = packages.findIndex((p) => p.id === pkg.id);

  if (existingIndex >= 0) {
    packages[existingIndex] = pkg;
  } else {
    packages.push(pkg);
  }

  savePackages(packages);
}

export function getPackage(id: string): PostPackage | undefined {
  const packages = loadPackages();
  return packages.find((p) => p.id === id);
}

export function updatePackageStatus(
  id: string,
  status: PostPackage['status'],
  extra?: Partial<PostPackage>
): PostPackage | undefined {
  const packages = loadPackages();
  const pkg = packages.find((p) => p.id === id);

  if (!pkg) {
    console.error(`Package ${id} not found`);
    return undefined;
  }

  pkg.status = status;
  if (extra) {
    Object.assign(pkg, extra);
  }

  savePackages(packages);
  return pkg;
}

export function getPendingPackages(): PostPackage[] {
  return loadPackages().filter((p) => p.status === 'pending');
}

export function getApprovedPackages(): PostPackage[] {
  return loadPackages().filter((p) => p.status === 'approved');
}

export function getDecisionHistory(packageId: string): Decision[] {
  return loadDecisions().filter((d) => d.packageId === packageId);
}
