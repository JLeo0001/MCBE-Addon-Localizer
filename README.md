# MCBE 附加包本地化工具

[![build](https://github.com/JLeo0001/MCBE-Addon-Localizer/actions/workflows/build.yml/badge.svg)](https://github.com/JLeo0001/MCBE-Addon-Localizer/actions/workflows/build.yml)

Minecraft Bedrock 附加包（Addon）自动本地化工具，Android 与 Windows 双端，使用 Flutter 构建。

---

## 目录

- [功能](#功能)
- [界面结构](#界面结构)
- [快速开始](#快速开始)
- [配置参考](#配置参考)
- [包名与签名](#包名与签名)
- [CI 与发布](#ci-与发布)
- [架构](#架构)
- [许可](#许可)

---

## 功能

### 模组库

递归扫描任意目录：任何含 `manifest.json` 的文件夹都算一个包，任意层级的 `.mcaddon` / `.mcpack` / `.zip` 都算一个压缩包模组。资源包与行为包按 manifest 的 UUID 依赖自动配对。

支持按名称搜索、按「含资源包 / 含行为包 / 压缩包」筛选，以及多选后排队批量本地化。

### 本地化流程

进入本地化页会自动做一次 JSON / JS / `.lang` 规范化，随后是四个可单步、也可一键串跑的步骤：

| 步骤 | 说明 |
|:---|:---|
| ① Display Name 标准化 | 把实体/方块/物品 JSON 里的 `minecraft:display_name` 字面量改写为语言键，原文写入 `en_US.lang` 与目标语言文件 |
| ② 语言文件翻译 | 补齐 `languages.json`、复制源语言、补键，再按批调用文本 LLM 翻译；去重 + 本地缓存 + 术语表，重复内容不重复计费 |
| ③ 脚本提示本地化 | 解析 JS/TS，抽取 `sendMessage`、`title`、`tooltip`、`rawtext` 等可见字符串，翻译后原位回写，写回前做括号与引号平衡校验，失败即回滚 |
| ④ 本地化者署名 | 改写 `pack.name` 与 `manifest.header.name`，追加署名后缀，并在包根写入本地化协议 |

任务跑在全局任务中心，切换页面、打开设置都不会中断；顶部可随时「停止」。

### 图片本地化

按目录聚合图片，路径含 `book` / `guide` / `page` 的目录会置顶提示。两种方案：

- **视觉大模型**：整图发给支持图像输入输出的模型改画，返回图强制缩放回原始分辨率；
- **OCR 擦写**：识别文字 → 采样背景色填充 → 文本 LLM 翻译 → 按框重绘（字号自适应、对比度校正）→ 加水印。

原图一律备份到同目录 `_backup/`。

### 工具

| 工具 | 作用 |
|:---|:---|
| 灵动视效 | 增删资源包 `capabilities` 里的 `pbr` |
| 成就兼容 | 写入/移除 `metadata.product_type = "addon"` |
| 实体工具 | 扫描 `monster` family 实体与血量；为攻击玩家的实体补标签 |
| 包体检 | 静态检查 manifest、语言文件、JSON、图片，给出 0–100 分与问题清单 |
| 对照 | 逐条查看本次翻译的前后差异，可手工改写并直接写回文件 |
| 翻译记忆 | 浏览/搜索/删除本地翻译缓存 |

### 导出

- 资源包 + 行为包 → `.mcaddon`
- 仅一侧 → `.mcpack`

文件名 `<模组名>[ <版本>]<署名后缀>`，版本优先取模组名中的 `x.x.x`，否则取行为包、资源包的 manifest 版本。导出前会把 `header.name` / `header.description` 指向 `pack.name` / `pack.description`，让游戏按语言显示标题。

### 设置

分类卡片进入二级页面，改动即时生效、自动落盘，无需手动保存：

模组目录 · 目标语言 · 本地化署名 · 文本 LLM · 图片 LLM/OCR · 配置档 · 术语表 · 夸克网盘 · 百度网盘

---

## 界面结构

```
AppBar: 版本 · 当前模组状态 · 设置
├── 首屏（模组库）     搜索 / 筛选 / 多选批量 / 扫描诊断
└── 工具箱（底部导航）
    ├── 概览           当前模组、运行中任务、快捷操作、最近打开、日志
    ├── 本地化         四步 + 一键 + 进度 + 日志
    ├── 图片           目录树 + 缩略图勾选 + 方案切换
    ├── 工具           灵动视效 / 成就 / 实体 / 体检 / 对照 / 记忆
    └── 导出           预览 + 目录选择 + 网盘
```

---

## 快速开始

### 使用发布包

到 [Releases](https://github.com/JLeo0001/MCBE-Addon-Localizer/releases) 下载：

| 文件 | 平台 |
|:---|:---|
| `mcbe-localizer-armv8.apk` | Android 64 位 |
| `mcbe-localizer-armv7.apk` | Android 32 位 |
| `mcbe-localizer-windows-x64.zip` | Windows x64，解压后运行 `mcbe-localizer.exe` |

### 从源码构建

需要 Flutter 3.47.x：

```bash
flutter pub get
flutter analyze --no-fatal-infos
flutter test
flutter build apk --release --split-per-abi
flutter build windows --release
```

---

## 配置参考

配置位于应用支持目录下的 `config.json`（Windows 为 `%APPDATA%\com.jleoz.belocalizer\arc_localizer\`）。

| 键 | 默认值 | 说明 |
|:---|:---|:---|
| `resource_pack_path` | `""` | 当前模组资源包路径 |
| `behavior_pack_path` | `""` | 当前模组行为包路径 |
| `current_mod_name` | `""` | 当前模组显示名 |
| `mods_base_dir` | `""` | 扫描根目录，留空用 `com.mojang` 默认位置 |
| `translator_credit` | `Local` | 写入包名的本地化者名称 |
| `target_language` | `zh_CN` | 目标语言代码 |
| `export_dir` | `""` | 导出目录，留空回落到 `~/Downloads` |
| `image_localize_method` | `llm` | `llm` 或 `ocr` |
| `ocr_endpoint` | `""` | OCR HTTP 服务地址 |
| `text_llm.base_url` / `.api_key` / `.model` / `.proxy` | OpenAI 兼容端点 | 文本翻译 |
| `image_llm.*` | 同上 | 图像改画 |
| `cloud_drives.quark.*` | `cookie` / `parent_fid` / `share_password` | 夸克网盘 |
| `cloud_drives.baidu.*` | `app_key` / `secret_key` / `app_name` / `remote_dir` | 百度网盘 |

LLM 端点需兼容 `POST {base_url}/chat/completions`。

---

## 包名与签名

- 应用包名：`com.jleoz.belocalizer`
- Release 签名：仓库根目录的 `publish.keystore` + `android/key.properties`；文件缺失时自动回退 debug 签名，保证浅克隆也能构建。
- CI 会用 `apksigner verify --print-certs` 打印证书 DN，便于确认发布包身份。

> ⚠️ 签名文件与口令当前提交在公开仓库中，任何拿到仓库的人都能用同一把钥匙签名。如果不希望如此，请把这两个文件移出仓库、改用 CI Secrets（`KEYSTORE_BASE64` / `STORE_PASSWORD` / `KEY_PASSWORD` / `KEY_ALIAS`），并考虑轮换密钥。

---

## CI 与发布

`.github/workflows/build.yml` 包含三个 job：

1. **android**：analyze → test → `flutter build apk --release --split-per-abi` → 校验签名
2. **windows**：`flutter build windows --release` 并打包 zip
3. **release**：汇总产物，创建 GitHub Release（tag 触发或手动指定 `release_tag`）

构建时会临时把 Gradle / Maven 源切到镜像，规避上游 504；失败自动重试三次。

---

## 架构

```
lib/
├── main.dart                 入口：权限申请 → 加载配置 → MaterialApp
├── app.dart                  应用壳：AppBar + 首屏/工具箱/设置 + 底部导航
├── theme.dart                品牌色与 M3 主题
├── core/
│   ├── config.dart           配置读写、防抖自动保存
│   ├── env.dart              平台路径、打开目录
│   ├── fsx.dart              JSONC、目录遍历、文件名清洗
│   ├── manifest.dart         manifest 读写、PBR / product_type / header 规范化
│   ├── lang_files.dart       .lang 解析、upsert、重建、行结构整理
│   ├── languages.dart        29 种语言、署名后缀
│   ├── mod_catalog.dart      递归扫描、RGB/BP 配对
│   ├── archive_probe.dart    压缩包探测、图标与描述、解包
│   ├── pack_rename.dart      显示名解析、两阶段重命名
│   ├── pack_ops.dart         格式化、署名、本地化协议
│   ├── display_name.dart     display_name → 语言键
│   ├── script_localize.dart  脚本字符串抽取/翻译/回写
│   ├── llm.dart              OpenAI 兼容客户端（文本/图像/心跳）
│   ├── translator.dart       去重、缓存、术语、分批重试
│   ├── pipeline.dart         四步流程（页面与批量共用）
│   ├── task_center.dart      全局任务中心（后台运行、进度、取消）
│   ├── projects.dart         最近打开
│   ├── profiles.dart         配置档
│   ├── glossary.dart         术语表
│   ├── report.dart           翻译前后对照
│   ├── health.dart           包体检
│   ├── imaging.dart          OCR 管线、重绘、水印
│   ├── export_service.dart   zip 打包、目录搬迁
│   ├── entity.dart           实体扫描与打标
│   ├── cloud.dart            夸克 / 百度网盘
│   └── models.dart           数据模型
└── ui/                       页面与通用组件
```

---

## 许可

MIT，版权归 JasonLeoZhou 所有。详见 [LICENSE](LICENSE)。
