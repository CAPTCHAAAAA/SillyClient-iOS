/**
 * 原生注册表/安装器的报错是英文内部不变量（例如
 * "Default installations must be direct children of the instance root"）。
 * 它们会直接显示在向导与迁移面板里，所以在这里翻译成可执行的中文提示；
 * 未命中映射的消息原样返回。
 */
const NATIVE_ERROR_HINTS: Array<[RegExp, string | ((match: RegExpMatchArray) => string)]> = [
  [
    /Default installations must be direct children of the instance root/i,
    "该位置在实例存放文件夹的子文件夹里；请选择存放文件夹本身，或实例之外的文件夹",
  ],
  [
    /Custom installation destinations must be new or empty/i,
    "该文件夹已存在且不为空；请选择一个新文件夹",
  ],
  [
    /Installation locations cannot overlap another registered instance/i,
    "该位置与已有实例目录重叠；请换一个文件夹",
  ],
  [
    /must be within an approved root/i,
    "该路径不在允许的存储范围内；请用「浏览」选择内部存储里的文件夹",
  ],
  [
    /An installation root cannot be used as a relocation destination/i,
    "不能把实例存放文件夹本身当作迁移目标；请选择它下面的新文件夹",
  ],
  [
    /only the application-private area and shared storage are available/i,
    "该磁盘位置不可用；请选择内部存储里的文件夹",
  ],
  [
    /This iCloud installation folder is not downloaded locally/i,
    "该 iCloud 文件夹尚未下载到本地；请先在「文件」中下载，或改用「我的 iPhone」本地文件夹",
  ],
  [
    /(?:The selected provider cannot retain local runtime files|NSPOSIXErrorDomain:45|Operation not supported)/i,
    "当前存储位置不支持直接运行本地酒馆文件（例如部分网盘或 iCloud 目录），请改选「我的 iPhone」中的本地文件夹",
  ],
  [
    /(?:Select this installation root again|Installation root bookmark is stale|Installation root authorization was lost|Installation folder authorization could not be restored)/i,
    "该文件夹的持久化访问授权已失效或尚未完成授权，请重新点击「浏览」选择该文件夹",
  ],
  [
    /A filesystem root or sandbox ancestor cannot be an installation root/i,
    "不能选择根目录或应用容器上级目录；请进入具体目标文件夹后再点击右上角「打开」确认",
  ],
  [
    /(?:has no security-scoped authorization|did not provide an authorized directory URL)/i,
    "系统未能授予该文件夹的安全访问权限；请重新在「文件」选择器中进入目标文件夹后点击「打开」",
  ],
  [
    /Another picker is active/i,
    "系统文件选择器尚未关闭或正忙，请稍候重试",
  ],
  [
    /Links and non-regular files were preserved/i,
    "所选目标包含不受支持的替身/符号链接或特殊文件，请选择常规本地文件夹或文件",
  ],
  [
    /Installation folder selection failed at ([^\s:]+)(?:\s*\[([^\]]+)\])?:\s*(.+)/i,
    (match) => {
      const stage = match[1];
      const domain = match[2] ? ` ${match[2]}` : "";
      const detail = match[3];
      return `目录选择失败（${stage}${domain}）：${detail}；建议先选择「我的 iPhone」下的本地文件夹重试`;
    },
  ],
];

export function humanizeNativeError(message: string | null | undefined): string {
  const text = (message ?? "").trim();
  if (!text) return "操作未完成，请重试";
  for (const [pattern, hint] of NATIVE_ERROR_HINTS) {
    const match = text.match(pattern);
    if (match) return typeof hint === "function" ? hint(match) : hint;
  }
  return text;
}
