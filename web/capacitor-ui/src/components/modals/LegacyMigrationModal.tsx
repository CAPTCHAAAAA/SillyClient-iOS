import React, { useState, useEffect, useRef } from "react";
import { X, FolderSync, CheckCircle2, AlertCircle, ArrowRight, Loader2 } from "lucide-react";
import { cn, formatDisplayVersion } from "../../lib/utils";
import { LAYERS } from "../../constants/layers";
import { LayerBackdrop } from "../common/LayerBackdrop";
import { TarvenEnv } from "../../capacitor-plugin";
import type { InstanceRelocationResult } from "../../capacitor-plugin";
import { relocateLegacyItems } from "../../lib/instance-location-state";

export interface LegacyMigrationItem {
  instanceId: string;
  name: string;
  currentPath: string;
  targetPath: string;
  version?: string;
}

export interface LegacyMigrationModalProps {
  isOpen: boolean;
  isClosing?: boolean;
  onClose: () => void;
  isLight: boolean;
  glassBg: string;
  legacyInstances: LegacyMigrationItem[];
  isWindows?: boolean;
  isIOS?: boolean;
  onBusyChange?: (busy: boolean) => void;
  onInstanceRelocated?: (previousId: string, result: InstanceRelocationResult) => void;
  onMigrationComplete?: () => void;
}

/**
 * 新版本旧路径实例全屏一键迁移向导 (LegacyMigrationModal)
 * 在 WhatsNewModal 之后呈现，100% 同构轻拟物材质与毛玻璃质感，
 * 引导用户将 C 盘 AppData 的旧实例无损迁移至软件目录 instances/ 统一管理。
 */
export const LegacyMigrationModal: React.FC<LegacyMigrationModalProps> = ({
  isOpen,
  isClosing = false,
  onClose,
  isLight,
  glassBg,
  legacyInstances,
  isWindows = false,
  isIOS = false,
  onBusyChange,
  onInstanceRelocated,
  onMigrationComplete,
}) => {
  const [migrating, setMigrating] = useState(false);
  const [currentMigratingId, setCurrentMigratingId] = useState<string | null>(null);
  const [completedIds, setCompletedIds] = useState<string[]>([]);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [isAllDone, setIsAllDone] = useState(false);
  const [completedLocations, setCompletedLocations] = useState<Record<string, InstanceRelocationResult>>({});
  const completedRef = useRef(new Set<string>());
  const busyRef = useRef(false);
  const sessionRef = useRef(0);
  useEffect(() => {
    sessionRef.current++;
    if (isOpen) {
      completedRef.current = new Set();
      setCompletedIds([]);
      setErrorMsg(null);
      setCompletedLocations({});
      setIsAllDone(false);
    }
    return () => { sessionRef.current++; };
  }, [isOpen]);

  if (!isOpen && !isClosing) return null;

  const handleStartMigration = async () => {
    if (busyRef.current || isClosing || legacyInstances.length === 0) return;
    const session = sessionRef.current;
    busyRef.current = true;
    onBusyChange?.(true);
    setMigrating(true);
    setErrorMsg(null);

    try {
      await relocateLegacyItems(legacyInstances, completedRef.current, async (item) => {
        setCurrentMigratingId(item.instanceId);
        return TarvenEnv.relocateInstance({
          instanceId: item.instanceId,
          targetPath: item.targetPath,
          installPath: item.currentPath,
        });
      }, (item, result) => {
        onInstanceRelocated?.(item.instanceId, result);
        if (session !== sessionRef.current) return;
        completedRef.current.add(item.instanceId);
        setCompletedIds([...completedRef.current]);
        setCompletedLocations(previous => ({ ...previous, [item.instanceId]: result }));
      }, () => {
        if (session !== sessionRef.current) throw new Error("迁移视图已关闭");
      });
      setIsAllDone(true);
      onMigrationComplete?.();
    } catch (err: any) {
      if (session === sessionRef.current) setErrorMsg(err?.message || "迁移过程中发生异常，未完成项保留原状");
    } finally {
      busyRef.current = false;
      onBusyChange?.(false);
      if (session === sessionRef.current) {
        setMigrating(false);
        setCurrentMigratingId(null);
      }
    }
  };

  return (
    <>
      {/* 全屏虚化遮罩 */}
      <LayerBackdrop
        isOpen={isOpen}
        isClosing={isClosing}
        onClick={migrating ? undefined : onClose}
        zIndex={LAYERS.MODAL_BACKDROP}
        blur={false}
        className={cn(
          "transition-all duration-300",
          isLight ? "bg-black/25 backdrop-blur-[36px]" : "bg-black/60 backdrop-blur-[36px]"
        )}
      />

      {/* 居中任务画布 */}
      <div
        className={cn(
          "ios-task-surface fixed rounded-3xl flex flex-col overflow-hidden backdrop-blur-[40px] saturate-180",
          glassBg,
          isLight && "is-light",
          isClosing ? "animate-clone-panel-exit" : "animate-clone-panel"
        )}
        style={{
          zIndex: LAYERS.MODAL_SURFACE,
          top: "50%",
          left: "50%",
          transform: "translate(-50%, -50%)",
          width: "min(580px, calc(100vw - 2rem))",
          maxHeight: "min(84vh, calc(100vh - 3.5rem))",
        }}
      >
        {/* 顶部标题栏 */}
        <div
          className={cn(
            "flex items-center justify-between px-6 h-14 flex-shrink-0 border-b",
            isLight ? "border-black/[0.06]" : "border-white/[0.06]"
          )}
        >
          <div className="flex items-center gap-2.5">
            <span
              className={cn(
                "p-1.5 rounded-xl border-0 flex items-center justify-center",
                isLight ? "bg-black/[0.05] text-[#1a1625]" : "bg-white/[0.08] text-white"
              )}
            >
              <FolderSync className="w-4 h-4" />
            </span>
            <span className={cn("text-sm font-semibold tracking-tight", isLight ? "text-[#1a1625]" : "text-white")}>
              检测到旧版实例 · 一键无损迁移
            </span>
          </div>
          {!migrating && (
            <button
              onClick={onClose}
              className={cn(
                "p-1.5 rounded-full transition-colors",
                isLight
                  ? "hover:bg-black/5 text-[#1a1625]/30 hover:text-[#1a1625]/60"
                  : "hover:bg-white/5 text-white/30 hover:text-white/60"
              )}
              aria-label="关闭"
            >
              <X className="w-4 h-4" />
            </button>
          )}
        </div>

        {/* 正文区域 */}
        <div className="flex-1 overflow-y-auto p-6 space-y-4 scrollbar-subtle">
          {/* 说明卡片 */}
          <div
            className={cn(
              "rounded-2xl p-4 text-xs leading-relaxed border",
              isLight
                ? "bg-black/[0.025] border-black/[0.05] text-[#1a1625]/75"
                : "bg-white/[0.03] border-white/[0.06] text-white/75"
            )}
          >
            {isWindows ? "旧版系统目录中的实例可迁移至客户端默认的 " : isIOS ? "旧版目录中的实例可迁移至应用 Documents 下的 " : "旧版私有目录中的实例可迁移至应用外部的 "}<code className="px-1 py-0.5 rounded bg-black/5 dark:bg-white/10 font-mono text-[11px]">instances/</code> 目录。跨存储采用校验复制，原目录保留情况将在完成后列出。
            <div className="mt-1.5 text-[11px] opacity-70">
              迁移将无损保留所有聊天记录、角色、扩展与配置，并自动同步底层注册表，迁移后可直接启动继续使用。
            </div>
          </div>

          {/* 待迁移列表 */}
          <div className="space-y-2">
            <div className={cn("text-xs font-medium px-1", isLight ? "text-[#1a1625]/60" : "text-white/60")}>
              待迁移实例 ({legacyInstances.length})
            </div>

            <div className="space-y-2">
              {legacyInstances.map((item) => {
                const isCompleted = completedIds.includes(item.instanceId);
                const isCurrent = currentMigratingId === item.instanceId;

                return (
                  <div
                    key={item.instanceId}
                    className={cn(
                      "rounded-xl p-3 border transition-all text-xs",
                      isLight
                        ? "bg-black/[0.02] border-black/[0.06]"
                        : "bg-white/[0.03] border-white/[0.06]"
                    )}
                  >
                    <div className="flex items-center justify-between mb-1.5">
                      <div className="flex min-w-0 items-center gap-2">
                        <span className={cn("font-semibold truncate", isLight ? "text-[#1a1625]" : "text-white")} title={item.name}>
                          {item.name}
                        </span>
                        {item.version && (
                          <span
                            className={cn(
                              "px-1.5 py-0.5 rounded text-[10px] border",
                              isLight
                                ? "bg-black/[0.04] text-[#1a1625]/60 border-black/[0.06]"
                                : "bg-white/[0.06] text-white/60 border-white/[0.08]"
                            )}
                          >
                            {formatDisplayVersion(item.version)}
                          </span>
                        )}
                      </div>

                      {/* 状态徽标 */}
                      {isCompleted ? (
                        <span className="flex items-center gap-1 text-[11px] text-emerald-500 font-medium">
                          <CheckCircle2 className="w-3.5 h-3.5" />
                          已就绪
                        </span>
                      ) : isCurrent ? (
                        <span className="flex items-center gap-1 text-[11px] text-amber-500 font-medium animate-pulse">
                          <Loader2 className="w-3.5 h-3.5 animate-spin" />
                          搬迁中
                        </span>
                      ) : (
                        <span className={cn("text-[11px]", isLight ? "text-[#1a1625]/40" : "text-white/40")}>
                          待迁移
                        </span>
                      )}
                    </div>

                    {/* 路径变化 */}
                    <div className="flex items-center gap-1.5 font-mono text-[10.5px] truncate opacity-70">
                      <span className="truncate max-w-[45%]" title={item.currentPath}>
                        {item.currentPath}
                      </span>
                      <ArrowRight className="w-3 h-3 flex-shrink-0 opacity-40" />
                      <span className="truncate max-w-[45%] text-emerald-500/90" title={completedLocations[item.instanceId]?.newPath || item.targetPath}>
                        {completedLocations[item.instanceId]?.newPath || item.targetPath}
                      </span>
                    </div>
                    {completedLocations[item.instanceId]?.retainedSourcePath && (
                      <p className="mt-1 truncate text-[10px] opacity-60" title={completedLocations[item.instanceId].retainedSourcePath}>
                        原目录保留：{completedLocations[item.instanceId].retainedSourcePath}
                      </p>
                    )}
                  </div>
                );
              })}
            </div>
          </div>

          {/* 错误提示 */}
          {errorMsg && (
            <div className="p-3 rounded-xl bg-red-500/10 border border-red-500/20 text-red-400 text-xs flex items-start gap-2">
              <AlertCircle className="w-4 h-4 flex-shrink-0 mt-0.5" />
              <span>{errorMsg}</span>
            </div>
          )}
        </div>

        {/* 底部按钮操作栏 */}
        <div
          className={cn(
            "p-5 flex-shrink-0 border-t flex items-center justify-end gap-2.5",
            isLight ? "border-black/[0.06] bg-black/[0.01]" : "border-white/[0.06] bg-white/[0.01]"
          )}
        >
          {isAllDone ? (
            <button
              onClick={onClose}
              className={cn(
                "motion-control px-6 h-9 rounded-full text-xs font-semibold flex items-center justify-center gap-1.5 transition-all border",
                isLight
                  ? "bg-black/[0.08] border-black/[0.10] text-[#1a1625] hover:bg-black/[0.14]"
                  : "bg-white/20 border-white/15 text-white hover:bg-white/30"
              )}
            >
              <CheckCircle2 className="w-3.5 h-3.5" />
              全部迁移完成 · 进入控制台
            </button>
          ) : (
            <>
              {!migrating && (
                <button
                  type="button"
                  onClick={onClose}
                  className={cn(
                    "motion-control px-4 h-9 rounded-full text-xs font-medium transition-all border",
                    isLight
                      ? "bg-black/[0.04] border-black/[0.06] text-[#1a1625]/60 hover:bg-black/[0.08]"
                      : "bg-white/[0.08] border-white/[0.06] text-white/60 hover:bg-white/[0.14]"
                  )}
                >
                  稍后在管理面板迁移
                </button>
              )}
              <button
                type="button"
                disabled={migrating || legacyInstances.length === 0}
                onClick={handleStartMigration}
                className={cn(
                  "motion-control px-5 h-9 rounded-full text-xs font-semibold flex items-center justify-center gap-1.5 transition-all border disabled:opacity-50",
                  isLight
                    ? "bg-black/[0.08] border-black/[0.10] text-[#1a1625] hover:bg-black/[0.14] active:bg-black/[0.18]"
                    : "bg-white/20 border-white/15 text-white hover:bg-white/30 active:bg-white/35"
                )}
              >
                {migrating ? (
                  <>
                    <Loader2 className="w-3.5 h-3.5 animate-spin" />
                    正在搬迁数据与更新注册表...
                  </>
                ) : (
                  <>
                    <FolderSync className="w-3.5 h-3.5" />
                    一键无损迁移全部实例
                  </>
                )}
              </button>
            </>
          )}
        </div>
      </div>
    </>
  );
};
