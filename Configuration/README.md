# 本地与随包密钥

DeepSeek 优先读取 `Secrets.local.json` 中的 `deepseek_api_key`。该配置文件缺失时，兼容工程上一级 `key` 目录的原有 Finder 文本剪辑。

千问默认读取工程上一级的 `key/qwen-bailian.key`。可在 `Secrets.local.json` 中添加 `qwen_api_key` 覆盖独立文件。要使用独立文件，请省略该字段。`Secrets.example.json` 提供空白模板，真实凭据应存放于被 Git 忽略的 `Secrets.local.json` 或工程外部的 `key` 目录。

Debug 与 Release 使用同一套配置，分别生成包内的 `dev-key.txt` 和 `qwen-key.txt`。修改配置后重新构建即可更新资源。脚本以 `0600` 权限原子写入资源，配置无效时清理旧资源并让构建失败。将某个配置字段设为空字符串会禁用对应的随包密钥并移除旧资源。

应用按服务将随包密钥导入独立的 `AfterFirstUnlockThisDeviceOnly` 钥匙串条目。没有有效凭据时导入，手工保存的密钥和来源不明的已有密钥均保留。当前凭据仍匹配上次成功导入的 SHA-256 指纹且未被标记为手工保存时，才随新包密钥轮换。`UserDefaults` 只保存指纹与来源标记。

密钥值不进入程序源码、Git、用户导出备份或日志；生成资源和构建目录仍被忽略。安装包内置密钥可被提取，分发范围与说明见[项目 README](../README.md)。

「数据 → 设置」的连接检查可核对当前服务、请求模型、API 返回模型及推理和输出预算参数。排查真机时，以该设备的设置和检查结果为准。
