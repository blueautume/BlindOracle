# 项目协作规则

- 用户要求：以后每批修改提交前都升级应用版本号，包括代码、资源、配置和文档修改。
- 默认同时递增补丁版本和 Build；每个提交递增一次，同一批修改中的反复编辑、构建和测试不重复递增。用户明确指定版本时按其要求处理。
- 单一版本源为 `Configuration/Version.json`。提交前运行一次 `python3 Scripts/version.py`，同步 Xcode 的 Debug/Release、README 和 Validation；本批已经升级时仅运行 `python3 Scripts/version.py --check`。
- 暂存上述版本文件后，运行 `python3 Scripts/version.py --check-staged`。提交钩子会检查暂存区版本相对 HEAD 递增，并保留原有密钥检查；不要跳过钩子。
- 工程生成脚本读取同一版本源。不要在构建阶段自动递增版本，避免重复编译消耗 Build。
- 保持 Bundle ID `com.lihao.BlindOracle` 不变。版本升级不改变资料目录、钥匙串标识或用户数据。
- Validation 中的历史测试证据保留其实际所属版本；只验证了版本配置时，不宣称重跑了所有功能测试。
