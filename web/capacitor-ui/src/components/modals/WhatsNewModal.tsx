import React from "react";
import { X } from "lucide-react";
import { cn } from "../../lib/utils";
import { LAYERS } from "../../constants/layers";
import { LayerBackdrop } from "../common/LayerBackdrop";
import { APP_VERSION } from "../../constants/app-version";

export interface WhatsNewModalProps {
  isOpen: boolean;
  isClosing?: boolean;
  onClose: () => void;
  isLight: boolean;
  glassBg: string;
}

/**
 * 版本核心更新全屏虚化画布 (WhatsNewModal)
 * 纯正轻拟物扁平 + 微边框 + 低亮度中等透明度设计，杜绝冗余图标与花哨修饰。
 */
export const WhatsNewModal: React.FC<WhatsNewModalProps> = ({
  isOpen,
  isClosing = false,
  onClose,
  isLight,
  glassBg,
}) => {
  if (!isOpen && !isClosing) return null;

  return (
    <>
      {/* 全屏虚化遮罩 */}
      <LayerBackdrop
        isOpen={isOpen}
        isClosing={isClosing}
        onClick={onClose}
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
          width: "min(560px, calc(100vw - 2rem))",
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
                "px-2.5 py-1 rounded-xl text-[10px] font-mono font-medium uppercase border-0",
                isLight
                  ? "bg-black/[0.04] text-[#1a1625]/60"
                  : "bg-white/[0.06] text-white/60"
              )}
            >
              v{APP_VERSION}
            </span>
            <span className={cn("text-sm font-semibold tracking-tight", isLight ? "text-[#1a1625]" : "text-white")}>
              版本主要更新
            </span>
          </div>
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
        </div>

        {/* 正文：轻微色差无边框区域（轻拟物轻盈色块，直达核心） */}
        <div className="flex-1 overflow-y-auto p-6 space-y-3 scrollbar-subtle">
          
          {/* 01 可以使用什么新功能 */}
          <div
            className={cn(
              "p-4 rounded-xl transition-colors",
              isLight ? "bg-black/[0.035]" : "bg-white/[0.04]"
            )}
          >
            <div className="flex items-center justify-between mb-1.5">
              <span className={cn("text-[13px] font-semibold tracking-tight", isLight ? "text-[#1a1625]/90" : "text-white/90")}>
                新保护：实例启动防误装
              </span>
              <span className={cn("text-[10px] font-mono", isLight ? "text-[#1a1625]/35" : "text-white/30")}>
                01
              </span>
            </div>
            <div className={cn("text-[11.5px] leading-relaxed", isLight ? "text-[#1a1625]/65" : "text-white/65")}>
              实例文件夹丢失或被移动时，启动不再静默全新安装顶替你的数据，而是明确提示并引导恢复。创建本地实例必须显式选择安装文件夹，存放位置完全由你指定。
            </div>
          </div>

          {/* 02 可以看到什么新更新 */}
          <div
            className={cn(
              "p-4 rounded-xl transition-colors",
              isLight ? "bg-black/[0.035]" : "bg-white/[0.04]"
            )}
          >
            <div className="flex items-center justify-between mb-1.5">
              <span className={cn("text-[13px] font-semibold tracking-tight", isLight ? "text-[#1a1625]/90" : "text-white/90")}>
                新功能：实例导出 ZIP 备份
              </span>
              <span className={cn("text-[10px] font-mono", isLight ? "text-[#1a1625]/35" : "text-white/30")}>
                02
              </span>
            </div>
            <div className={cn("text-[11.5px] leading-relaxed", isLight ? "text-[#1a1625]/65" : "text-white/65")}>
              「实例管理 → 存储路径」新增导出实例：一键把聊天、角色、扩展与配置打包成 ZIP（不含依赖与程序文件），存入「文件」App 的 SillyClient/Exports 文件夹，随时带走或转移。
            </div>
          </div>

          {/* 03 可以体验到什么新优化 */}
          <div
            className={cn(
              "p-4 rounded-xl transition-colors",
              isLight ? "bg-black/[0.035]" : "bg-white/[0.04]"
            )}
          >
            <div className="flex items-center justify-between mb-1.5">
              <span className={cn("text-[13px] font-semibold tracking-tight", isLight ? "text-[#1a1625]/90" : "text-white/90")}>
                新优化：旧实例迁移逐项容错
              </span>
              <span className={cn("text-[10px] font-mono", isLight ? "text-[#1a1625]/35" : "text-white/30")}>
                03
              </span>
            </div>
            <div className={cn("text-[11.5px] leading-relaxed", isLight ? "text-[#1a1625]/65" : "text-white/65")}>
              检测到旧版存储位置的实例时会弹出迁移向导：多个实例逐项独立迁移，单个失败不影响其余，失败原因当场明示并可直接重试，完成后卡片自动指向新位置。
            </div>
          </div>

        </div>

        {/* 底部操作区 */}
        <div
          className={cn(
            "flex items-center justify-between px-6 py-4 flex-shrink-0 border-t",
            isLight ? "border-black/[0.06]" : "border-white/[0.06]"
          )}
        >
          <span className={cn("text-[11px]", isLight ? "text-[#1a1625]/40" : "text-white/40")}>
            可在「APP 设置 - 维护」中再次查看
          </span>
          <button
            onClick={onClose}
            className={cn(
              "flat-capsule motion-control h-8 px-5 rounded-full text-xs font-medium border-0",
              isLight
                ? "text-[#1a1625]/60 hover:text-[#1a1625]"
                : "text-white/60 hover:text-white"
            )}
          >
            开始使用
          </button>
        </div>
      </div>
    </>
  );
};
