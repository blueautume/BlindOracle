# 账号与服务配置

自 3.0.15 / Build 41 起，iOS 工程不再读取、生成或打包 AI 供应商凭据。历史 `Secrets.local.json` 保留在本地、不删除或提交；`Secrets.example.json` 和旧凭据脚本仅保留供历史配置回归使用。工程生成脚本的构建阶段清理旧产物中的 `dev-key.txt` / `qwen-key.txt`，并同步当前编译环境的中英文 App 显示名。

客户端正式环境使用 `https://wellecho.cn/xiazi-api/v1/`，独立测试环境使用 `https://wellecho.cn/xiazi-sandbox-api/v1/`。Apple 登录挑战、授权码交换、会话刷新、账号、余额和用量均走选定环境的账号 API；全部 AI 请求也通过该环境的 `ai/chat/completions/` 网关。客户端只持有自有账号 access/refresh token，不向服务器领取或保存 AI 供应商 key。

`ServiceEnvironment.current` 由启动入口冻结一次。3.0.306 起正式包直接恢复正式会话；在没有现存正式会话时，登录页的「测试访问」可以选择受邀 Sandbox。只有沙盒 Apple 登录请求发送 `sandbox_review_invite`，沙盒服务同时验证该邀请和 Apple 登录凭据。正式恢复和登录不等待 `AppTransaction` 或商店验证的联网预检。旧客户端的安装凭据和诊断兼容仍由现有后端处理。

开发签名 owner 包保留显式开关：

```sh
BLINDORACLE_SANDBOX=YES python3 Scripts/generate_project.py
# 使用 BlindOracle scheme 正常构建；Debug 与 Release 都会编译 BLINDORACLE_SANDBOX 条件。
# 构建完成后恢复仓库默认生产工程：
env -u BLINDORACLE_SANDBOX python3 Scripts/generate_project.py
```

仅向 `xcodebuild` 传同名用户设置不会替代工程生成开关。owner 包显示名「瞎子·测试」，Info 使用 `OwnerSandbox` / `Sandbox`，访问受服务器白名单约束。默认发布包「瞎子」使用 `ProductionWithSandboxReview` / `Production`。发布前检查 `BLINDORACLE_SANDBOX=NO`，再用同一送审归档验证邀请和 Sandbox 交易。

生产继续使用原 `com.lihao.BlindOracle.wellecho.account` Keychain service、任务和资料目录。既有 owner 构建沿用 `.sandbox` Keychain 与兼容存储。新审核沙盒使用 `.sandbox.review` 和 `BlindOracle-ReviewSandbox`，其中的账号删除只清理本测试空间。测试购买使用 Apple Sandbox，沙盒删号保留共享 Apple 登录授权。

沙盒购买只接受 StoreKit 的 Sandbox 交易，生产只接受 Production。服务器独立验单并确认环境与账号归属，不因测试而放宽。3.0.36 起客户端使用 Apple 当前 storefront，在中国大陆（CHN）选择 CNY 报价、美国（USA）选择 USD 报价；其他或未知地区暂不购买。`products/` 每个商品新增 `prices: [{storefront, currency, price_milliunits}]`，保留旧 `currency` / `price_milliunits` 字段供旧人民币客户端读取。新客户端缺少 `prices` 时只允许 CHN 旧协议；显式空数组不回退，USD 必须有美国报价。商品显示价格始终来自 StoreKit 的 `displayPrice`，币种和金额仍须精确匹配服务器批准的当地报价。加载时和付款前核对地区，监听地区变化后重新加载，不要求审核人员切换测试账号。服务器使用 Apple 验签交易中的 storefront、币种和金额进行最终入账判定，客户端不能提供或覆盖可信地区；历史报价保留供原交易延迟补单。

发布前检查 Debug/Release 包均不含 `dev-key.txt`、`qwen-key.txt` 或其他供应商凭据资源。密钥轮换只在服务器执行；不能通过重新打包 App 分发供应商密钥。真实联网测试需要有效的自有账号会话，并受同一网关任务、额度和并发策略约束；Debug 合成夹具不代表真实授权或付款成功。

开发者门户需为 `com.lihao.BlindOracle` 开启 Sign in with Apple，签名描述文件必须包含 `com.apple.developer.applesignin`。`App/BlindOracle.entitlements` 与 `Scripts/generate_project.py` 共同保存工程配置。Apple 私钥、供应商 key、服务器环境变量只在服务端配置，不能放进 App、README、日志或测试夹具。

3.0.16 起启动必须先登录，已有会话经服务器验证后自动恢复；未登录时只提供登录和协议政策入口。退出会回到门禁，本机人员资料与聊天不随账号删除，但需重新登录后才能访问。请在删除账号前分别清理需要删除的本机数据/历史。
