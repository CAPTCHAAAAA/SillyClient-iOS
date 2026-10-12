import React, { useState, useRef, useLayoutEffect } from "react";
import { ChevronDown, AlertTriangle, LoaderCircle, Info } from "lucide-react";
import { TarvenEnv } from "../../capacitor-plugin";
import { cn } from "../../lib/utils";
import { LAYERS } from "../../constants/layers";
import { PreinstallOptions } from "../instance/PreinstallOptions";
import type { GithubRelease, PreinstalledExtensionId } from "../../capacitor-plugin";

export type WizardMode = "local" | "remote";

export interface DiscoveredTavern {
  name: string;
  version: string;
  path: string;
}

export interface NewInstanceWizardModalProps {
  isOpen: boolean;
  isClosing?: boolean;
  onClose: () => void;
  isLight: boolean;
  glassBg: string;
  isWindows: boolean;
  newInstanceName: string;
  setNewInstanceName: (v: string) => void;
  newInstanceMode: WizardMode;
  switchInstanceMode: (mode: WizardMode) => void;
  newInstanceDir: string;
  setNewInstanceDir: (v: string) => void;
  onPickInstallFolder: () => void;
  newInstanceVersion: string;
  setNewInstanceVersion: (v: string) => void;
  newInstanceLocalZip: string | null;
  setNewInstanceLocalZip: (v: string | null) => void;
  newInstanceCompanionPresetEnabled: boolean;
  setNewInstanceCompanionPresetEnabled: React.Dispatch<React.SetStateAction<boolean>>;
  newInstanceExtensionIds: PreinstalledExtensionId[];
  setNewInstanceExtensionIds: React.Dispatch<React.SetStateAction<PreinstalledExtensionId[]>>;
  newInstanceUrl: string;
  setNewInstanceUrl: (v: string) => void;
  newRemoteAuthEnabled: boolean;
  setNewRemoteAuthEnabled: (v: boolean) => void;
  newRemoteAuthUsername: string;
  setNewRemoteAuthUsername: (v: string) => void;
  newRemoteAuthPassword: string;
  setNewRemoteAuthPassword: (v: string) => void;
  newInstanceError: string | null;
  isCreatingInstance: boolean;
  createInstance: () => void;
  releases: GithubRelease[];
  setReleases: (r: GithubRelease[]) => void;
  fetchingReleases: boolean;
  setFetchingReleases: (v: boolean) => void;
  verDropdownOpen: boolean;
  isVerDropdownClosing: boolean;
  openVersionDropdown: (trigger: HTMLElement) => void;
  closeVersionDropdown: () => void;
  addTerminalLog: (msg: string, level?: string) => void;
}

function NewInstanceField({
  label,
  children,
  action,
  isLight,
}: {
  label: string;
  children: React.ReactNode;
  action?: React.ReactNode;
  isLight?: boolean;
}) {
  return (
    <div className="space-y-1.5">
      <div className="flex items-center justify-between">
        <label
          className={cn(
            "text-xs font-medium",
            isLight ? "text-[#1a1625]/75" : "text-white/75"
          )}
        >
          {label}
        </label>
        {action}
      </div>
      {children}
    </div>
  );
}

/**
  * 新建实例向导模态框 (NewInstanceWizardModal)
  * 1. 严格绝对居中；
  * 2. 本地模式与远程模式同位驻留 DOM，实现平滑自适应高度跟随与交叉溶变过渡；
  * 3. 彻底下线历史数据迁移模式，创建链路直观清爽。
  */
export const NewInstanceWizardModal: React.FC<NewInstanceWizardModalProps> = ({
  isOpen,
  isClosing,
  onClose,
  isLight,
  glassBg,
  isWindows,
  newInstanceName,
  setNewInstanceName,
  newInstanceMode,
  switchInstanceMode,
  newInstanceDir,
  setNewInstanceDir,
  onPickInstallFolder,
  newInstanceVersion,
  setNewInstanceVersion,
  newInstanceLocalZip,
  setNewInstanceLocalZip,
  newInstanceCompanionPresetEnabled,
  setNewInstanceCompanionPresetEnabled,
  newInstanceExtensionIds,
  setNewInstanceExtensionIds,
  newInstanceUrl,
  setNewInstanceUrl,
  newRemoteAuthEnabled,
  setNewRemoteAuthEnabled,
  newRemoteAuthUsername,
  setNewRemoteAuthUsername,
  newRemoteAuthPassword,
  setNewRemoteAuthPassword,
  newInstanceError,
  isCreatingInstance,
  createInstance,
  releases,
  setReleases,
  fetchingReleases,
  setFetchingReleases,
  verDropdownOpen,
  isVerDropdownClosing,
  openVersionDropdown,
  closeVersionDropdown,
  addTerminalLog,
}) => {
  const wizardContainerRef = useRef<HTMLDivElement>(null);
  const wizardLocalRef = useRef<HTMLDivElement>(null);
  const wizardRemoteRef = useRef<HTMLDivElement>(null);
  const [wizardHeight, setWizardHeight] = useState<number | null>(null);
  const [releaseFetchError, setReleaseFetchError] = useState<string | null>(null);

  // 同步测量当前激活模式的实际高度，在同一渲染帧提交以保证平滑过渡
  useLayoutEffect(() => {
    if (!isOpen) return;
    const targetEl =
      newInstanceMode === "local"
        ? wizardLocalRef.current
        : wizardRemoteRef.current;
    if (!targetEl) return;

    const updateHeight = (entry?: ResizeObserverEntry) => {
      const h = entry?.borderBoxSize?.[0]?.blockSize ?? targetEl.offsetHeight;
      if (h > 0) setWizardHeight(Math.ceil(h));
    };

    updateHeight();

    if (typeof ResizeObserver !== "undefined") {
      const ro = new ResizeObserver(([entry]) => {
        updateHeight(entry);
      });
      ro.observe(targetEl);
      return () => ro.disconnect();
    }
  }, [
    newInstanceMode,
    newInstanceCompanionPresetEnabled,
    newInstanceExtensionIds,
    newRemoteAuthEnabled,
    isOpen,
  ]);

  if (!isOpen && !isClosing) return null;

  return (
    <div
      className={cn(
        "ios-task-surface fixed rounded-2xl flex flex-col overflow-hidden backdrop-blur-[40px] saturate-180",
        glassBg,
        isLight && "is-light",
        isClosing ? "animate-clone-panel-exit" : "animate-clone-panel"
      )}
      style={{
        zIndex: LAYERS.MODAL,
        top: "50%",
        left: "50%",
        transform: "translate(-50%, -50%)",
        width: "min(460px, calc(100vw - 2rem))",
        maxHeight: "min(85vh, calc(100vh - 4rem))",
      }}
    >
      {/* 头部 */}
      <div
        className={cn(
          "flex items-center justify-between px-5 h-12 flex-shrink-0 border-b",
          isLight ? "border-black/[0.06]" : "border-white/[0.06]"
        )}
      >
        <span
          className={cn(
            "text-sm font-semibold",
            isLight ? "text-[#1a1625]" : "text-white"
          )}
        >
          新建酒馆实例
        </span>
        <button
          onClick={onClose}
          className={cn(
            "motion-control text-xs px-2.5 py-1 rounded-lg transition-colors",
            isLight
              ? "text-[#1a1625]/40 hover:text-[#1a1625]/70 hover:bg-black/5"
              : "text-white/40 hover:text-white/70 hover:bg-white/5"
          )}
        >
          取消
        </button>
      </div>

      {/* 主体 */}
      <div className="flex-1 overflow-y-auto p-5 space-y-4 scrollbar-subtle">
        {/* 模式切换 (本地 / 远程) */}
        <div
          className="ios-choice-track"
          role="group"
          aria-label="实例类型选择"
        >
          <button
            type="button"
            aria-pressed={newInstanceMode === "local"}
            onClick={() => switchInstanceMode("local")}
            className="ios-choice-control py-2 text-xs font-medium border flex items-center justify-center gap-1.5 transition-colors duration-500 ease-[cubic-bezier(0.22,1,0.36,1)]"
          >
            本地酒馆
          </button>
          <button
            type="button"
            aria-pressed={newInstanceMode === "remote"}
            onClick={() => switchInstanceMode("remote")}
            className="ios-choice-control py-2 text-xs font-medium border flex items-center justify-center gap-1.5 transition-colors duration-500 ease-[cubic-bezier(0.22,1,0.36,1)]"
          >
            远程酒馆
          </button>
        </div>

        {/* 模式配置切换容器 */}
        <div
          ref={wizardContainerRef}
          className="motion-panel-stack"
          style={{ height: wizardHeight ? `${wizardHeight}px` : undefined }}
        >
          {/* 本地模式面板 */}
          <div
            ref={wizardLocalRef}
            className={cn(
              "motion-panel-face w-full space-y-4",
              newInstanceMode === "local"
                ? "is-active relative pointer-events-auto"
                : "absolute inset-x-0 top-0 pointer-events-none select-none"
            )}
            aria-hidden={newInstanceMode !== "local"}
            inert={newInstanceMode !== "local"}
          >
            {/* 实例名称 */}
            <NewInstanceField label="实例名称" isLight={isLight}>
              <input
                type="text"
                value={newInstanceName}
                onChange={(e) => setNewInstanceName(e.target.value)}
                placeholder="我的酒馆"
                className={cn(
                  "ios-field-control motion-control w-full h-9 px-3 rounded-xl border text-xs transition-colors",
                  isLight
                    ? "bg-black/[0.04] border-black/[0.08] text-[#1a1625] placeholder:text-black/30 focus:border-black/20"
                    : "bg-white/[0.04] border-white/[0.08] text-white placeholder:text-white/30 focus:border-white/20"
                )}
              />
            </NewInstanceField>

            {/* 存放位置 (必选) */}
            <NewInstanceField label="存放位置" isLight={isLight}>
              <div className="flex items-center gap-2">
                <input
                  type="text"
                  value={newInstanceDir}
                  onChange={(e) => setNewInstanceDir(e.target.value)}
                  placeholder="点击右侧「浏览」选择文件夹"
                  className={cn(
                    "ios-field-control motion-control flex-1 min-w-0 h-9 px-3 rounded-xl border text-xs transition-colors font-mono",
                    isLight
                      ? "bg-black/[0.04] border-black/[0.08] text-[#1a1625] placeholder:text-black/30 focus:border-black/20"
                      : "bg-white/[0.04] border-white/[0.08] text-white placeholder:text-white/30 focus:border-white/20"
                  )}
                />
                <button
                  type="button"
                  onClick={onPickInstallFolder}
                  className={cn(
                    "motion-control h-9 px-3 rounded-xl text-[11px] font-medium border flex-shrink-0 transition-colors",
                    isLight
                      ? "border-black/[0.08] text-[#1a1625]/50 hover:bg-black/[0.04]"
                      : "border-white/[0.08] text-white/50 hover:bg-white/[0.04]"
                  )}
                >
                  浏览
                </button>
              </div>
              <p
                className={cn(
                  "text-[10px] leading-relaxed",
                  isLight ? "text-[#1a1625]/45" : "text-white/40"
                )}
              >
                必选：点「浏览」选择存放文件夹，实例会创建在该文件夹内，之后创建的实例默认也放在这里。旧酒馆数据可在创建完成后，于「实例管理 → 存储路径 → 导入数据（ZIP）」无损导入。
              </p>
            </NewInstanceField>

            {/* 版本选择 */}
            <NewInstanceField
              label="SillyTavern 版本"
              action={
                newInstanceLocalZip && (
                  <button
                    type="button"
                    onClick={() => {
                      setNewInstanceLocalZip(null);
                      setNewInstanceVersion(releases[0]?.tag || "release");
                    }}
                    className={cn(
                      "motion-control text-[10px] transition-colors",
                      isLight
                        ? "text-[#1a1625]/40 hover:text-[#1a1625]/70"
                        : "text-white/40 hover:text-white/70"
                    )}
                  >
                    切回在线版本
                  </button>
                )
              }
              isLight={isLight}
            >
              {newInstanceLocalZip ? (
                <div
                  className={cn(
                    "h-9 px-3 rounded-xl border text-xs flex items-center justify-between",
                    isLight
                      ? "bg-black/[0.04] border-black/[0.08] text-[#1a1625]"
                      : "bg-white/[0.04] border-white/[0.08] text-white"
                  )}
                >
                  <span className="truncate text-xs">
                    本地压缩包: {newInstanceLocalZip.split(/[/\\\\]/).pop()}
                  </span>
                </div>
              ) : (
                <button
                  type="button"
                  onClick={(e) => {
                    if (verDropdownOpen) {
                      closeVersionDropdown();
                    } else {
                      openVersionDropdown(e.currentTarget);
                    }
                  }}
                  className={cn(
                    "motion-control w-full h-9 px-3 rounded-xl border text-xs flex items-center justify-between transition-colors",
                    isLight
                      ? "bg-black/[0.04] border-black/[0.08] text-[#1a1625]"
                      : "bg-white/[0.04] border-white/[0.08] text-white"
                  )}
                >
                  <span>
                    {fetchingReleases
                      ? "正在获取版本列表..."
                      : releases.find((r) => r.tag === newInstanceVersion)?.tag ||
                        newInstanceVersion ||
                        "最新正式版 (release)"}
                  </span>
                  <ChevronDown
                    className={cn(
                      "w-3.5 h-3.5 transition-transform duration-200",
                      isLight ? "text-[#1a1625]/40" : "text-white/40",
                      verDropdownOpen && "rotate-180"
                    )}
                  />
                </button>
              )}
            </NewInstanceField>

            {/* 预设扩展与伴侣 */}
            <PreinstallOptions
              themeEnabled={newInstanceCompanionPresetEnabled}
              setThemeEnabled={setNewInstanceCompanionPresetEnabled}
              extensionIds={newInstanceExtensionIds}
              setExtensionIds={setNewInstanceExtensionIds}
              isLight={isLight}
            />
          </div>

          {/* 远程模式面板 */}
          <div
            ref={wizardRemoteRef}
            className={cn(
              "motion-panel-face w-full space-y-4",
              newInstanceMode === "remote"
                ? "is-active relative pointer-events-auto"
                : "absolute inset-x-0 top-0 pointer-events-none select-none"
            )}
            aria-hidden={newInstanceMode !== "remote"}
            inert={newInstanceMode !== "remote"}
          >
            {/* 实例名称 */}
            <NewInstanceField label="实例名称" isLight={isLight}>
              <input
                type="text"
                value={newInstanceName}
                onChange={(e) => setNewInstanceName(e.target.value)}
                placeholder="远程酒馆"
                className={cn(
                  "ios-field-control motion-control w-full h-9 px-3 rounded-xl border text-xs transition-colors",
                  isLight
                    ? "bg-black/[0.04] border-black/[0.08] text-[#1a1625] placeholder:text-black/30 focus:border-black/20"
                    : "bg-white/[0.04] border-white/[0.08] text-white placeholder:text-white/30 focus:border-white/20"
                )}
              />
            </NewInstanceField>

            {/* 远程地址 */}
            <NewInstanceField label="服务地址" isLight={isLight}>
              <input
                type="text"
                value={newInstanceUrl}
                onChange={(e) => setNewInstanceUrl(e.target.value)}
                placeholder="http://192.168.1.100:8000"
                className={cn(
                  "ios-field-control motion-control w-full h-9 px-3 rounded-xl border text-xs font-mono transition-colors",
                  isLight
                    ? "bg-black/[0.04] border-black/[0.08] text-[#1a1625] placeholder:text-black/30 focus:border-black/20"
                    : "bg-white/[0.04] border-white/[0.08] text-white placeholder:text-white/30 focus:border-white/20"
                )}
              />
            </NewInstanceField>

            {/* 认证开关 */}
            <div className="pt-1">
              <div className="flex items-center justify-between">
                <span
                  className={cn(
                    "text-xs font-medium",
                    isLight ? "text-[#1a1625]/75" : "text-white/75"
                  )}
                >
                  启用 Basic Auth 认证
                </span>
                <div
                  className={cn(
                    "companion-preset flex-shrink-0 ml-3",
                    isLight && "is-light"
                  )}
                >
                  <button
                    type="button"
                    role="switch"
                    aria-label="启用 Basic Auth 认证"
                    aria-checked={newRemoteAuthEnabled}
                    onClick={() =>
                      setNewRemoteAuthEnabled(!newRemoteAuthEnabled)
                    }
                    className="companion-preset__switch motion-control"
                  >
                    <span className="companion-preset__knob" />
                  </button>
                </div>
              </div>

              {/* 认证表单折叠 */}
              <div
                className={cn(
                  "motion-accordion",
                  newRemoteAuthEnabled && "is-open"
                )}
                aria-hidden={!newRemoteAuthEnabled}
              >
                <div className="motion-accordion-inner space-y-3 pt-3">
                  <NewInstanceField label="用户名" isLight={isLight}>
                    <input
                      type="text"
                      value={newRemoteAuthUsername}
                      onChange={(e) =>
                        setNewRemoteAuthUsername(e.target.value)
                      }
                      placeholder="admin"
                      className={cn(
                        "ios-field-control motion-control w-full h-9 px-3 rounded-xl border text-xs transition-colors",
                        isLight
                          ? "bg-black/[0.04] border-black/[0.08] text-[#1a1625] placeholder:text-black/30 focus:border-black/20"
                          : "bg-white/[0.04] border-white/[0.08] text-white placeholder:text-white/30 focus:border-white/20"
                      )}
                    />
                  </NewInstanceField>
                  <NewInstanceField label="密码" isLight={isLight}>
                    <input
                      type="password"
                      value={newRemoteAuthPassword}
                      onChange={(e) =>
                        setNewRemoteAuthPassword(e.target.value)
                      }
                      placeholder="••••••••"
                      className={cn(
                        "ios-field-control motion-control w-full h-9 px-3 rounded-xl border text-xs transition-colors",
                        isLight
                          ? "bg-black/[0.04] border-black/[0.08] text-[#1a1625] placeholder:text-black/30 focus:border-black/20"
                          : "bg-white/[0.04] border-white/[0.08] text-white placeholder:text-white/30 focus:border-white/20"
                      )}
                    />
                  </NewInstanceField>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* 底部按钮 */}
      <div
        className={cn(
          "px-5 py-3 border-t flex items-center justify-between flex-shrink-0 gap-3",
          isLight ? "border-black/[0.06]" : "border-white/[0.06]"
        )}
      >
        <div className="min-w-0 flex-1">
          {newInstanceError && (
            <div className="flex items-center gap-1.5 text-red-400 text-xs truncate">
              <AlertTriangle className="w-3.5 h-3.5 flex-shrink-0" />
              <span className="truncate">{newInstanceError}</span>
            </div>
          )}
        </div>
        <div className="flex items-center gap-2 flex-shrink-0">
          <button
            type="button"
            onClick={createInstance}
            disabled={isCreatingInstance}
            className={cn(
              "motion-control px-4 h-9 rounded-xl text-xs font-medium transition-colors disabled:opacity-40",
              isLight
                ? "bg-black/[0.07] border border-black/[0.08] text-[#1a1625]/70 hover:text-[#1a1625]"
                : "bg-white/15 border border-white/15 text-white/70 hover:text-white"
            )}
          >
            {isCreatingInstance
              ? newInstanceMode === "remote"
                ? "验证连接"
                : "创建中..."
              : "创建"}
          </button>
        </div>
      </div>
    </div>
  );
};
