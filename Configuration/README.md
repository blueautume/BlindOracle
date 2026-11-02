# 本地开发密钥

复制 `Secrets.example.json` 为 `Secrets.local.json`，在 `deepseek_api_key` 填写自己的 DeepSeek 密钥。

`Secrets.local.json` 已加入 `.gitignore`，不要强制加入版本控制。仓库中的模板不含任何有效凭据。

Debug 构建从本地文件读取密钥，启动时同步到本机钥匙串；修改文件后重新构建运行即可生效。Release 不打包开发密钥，使用者在应用「数据 → 设置」中配置自己的密钥。

为兼容旧工程，本地配置文件不存在时，构建脚本仍可读取工程上一级 `key` 文件夹。存在但为空的本地配置不会回退到旧密钥。
