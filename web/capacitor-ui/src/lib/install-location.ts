import type { InstallPathMode } from "../capacitor-plugin";

export function cleanInstallPath(value: string): string | undefined {
  return value.trim().replace(/^["']|["']$/g, "").trim() || undefined;
}

function executablePath(value: string): string | undefined {
  const path = cleanInstallPath(value);
  if (path && /^[a-z][a-z0-9+.-]*:\/\//i.test(path)) {
    throw new Error("安装目录必须是可执行的本地路径，文档提供器位置只能用于导入");
  }
  return path;
}

export function installationSelection(selection: { path?: string; installPathMode?: InstallPathMode }) {
  const path = executablePath(selection.path || "");
  if (!path) throw new Error("目录选择器未返回实际路径");
  const mode = selection.installPathMode ?? "exact";
  if (mode !== "root" && mode !== "exact") throw new Error("目录选择器返回了无效的路径模式");
  return { path, mode };
}

/** Resolve an explicit parent selection or an exact path into the native execution target. */
export function exactInstallTarget(value: string, mode: InstallPathMode, instanceIdOrName: string): string | undefined {
  const path = executablePath(value);
  if (!path) return undefined;
  if (mode === "exact") return path;
  return buildInstanceSubfolder(path, instanceIdOrName);
}

export function sanitizeFolderName(name: string): string {
  return name
    .trim()
    .replace(/[\\/:*?"<>|\x00-\x1f]/g, "-")
    .replace(/^[. ]+|[. ]+$/g, "")
    .slice(0, 100) || "instance";
}

/**
 * Builds a dedicated subfolder for the instance under the parent directory.
 * If the path already ends with the instance name, avoids duplicating.
 */
export function buildInstanceSubfolder(parentDir: string, instanceName: string): string {
  const clean = parentDir.trim().replace(/^["']|["']$/g, "").trim().replace(/[\\/]+$/, "");
  const separator = clean.includes("\\") || /^[a-z]:/i.test(clean) ? "\\" : "/";
  const safeName = sanitizeFolderName(instanceName);
  const currentBase = clean.slice(clean.lastIndexOf(separator) + 1);
  if (currentBase.toLowerCase() === safeName.toLowerCase()) {
    return clean;
  }
  return `${clean}${separator}${safeName}`;
}

/**
 * Normalizes a raw instance display name or user input into an ASCII-safe native instance identity.
 * Strictly adheres to `^[A-Za-z0-9_-]{1,128}$` required by native runtimes.
 */
export function normalizeInstanceIdentity(name: string, fallback?: string): string {
  const asciiSlug = name
    .trim()
    .replace(/[^A-Za-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 64);
  if (asciiSlug && /^[A-Za-z0-9_-]{1,128}$/.test(asciiSlug)) {
    return asciiSlug;
  }
  const defaultFallback = fallback && /^[A-Za-z0-9_-]{1,128}$/.test(fallback)
    ? fallback
    : `inst-${Date.now().toString(36)}`;
  return defaultFallback;
}

