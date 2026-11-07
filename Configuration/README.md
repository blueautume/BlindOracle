# 账号与服务配置

自 3.0.15 / Build 41 起，iOS 工程不再读取、生成或打包 AI 供应商凭据。历史 `Secrets.local.json` 保留在本地、不删除或提交；`Secrets.example.json` 和旧凭据脚本仅保留供历史配置回归使用。工程生成脚本的构建阶段清理旧产物中的 `dev-key.txt` / `qwen-key.txt`，并同步当前编译环境的中英文 App 显示名。

客户端正式环境使用 `https://wellecho.cn/xiazi-api/v1/`，独立测试环境使用 `https://wellecho.cn/xiazi-sandbox-api/v1/`。Apple 登录挑战、授权码交换、会话刷新、账号、余额和用量均走选定环境的账号 API；全部 AI 请求也通过该环境的 `ai/chat/completions/` 网关。客户端只持有自有账号 access/refresh token，不向服务器领取或保存 AI 供应商 key。

`ServiceEnvironment.current` 是唯一环境入口，3.0.20 起默认发布包先验证 `AppTransaction.shared`，再冻结为 Production/Sandbox。未验证、未知环境或取凭据失败不默认放行任一环境、不创建账号/AI对象。3.0.21 起恢复按钮明确为「重新验证 App Store」，仅用户点击后调用会弹系统认证的 `AppTransaction.refresh()`；启动与自动恢复仍只读 shared。刷新后同样要求 Apple verified、匹配 Bundle ID 和支持的环境；取消或失败保留恢复页与原账号数据。自动 Sandbox Apple 登录携带 JWS 供服务器再次独立验签和绑定。

3.0.32 的有限重试与超时不改变上述信任边界。启动故障诊断固定发送到正式 API 的 `diagnostics/app-launch/`，不调用 `ServiceEnvironment.current`、不带登录头或安装凭据，仅报告固定字段；该接口不能用来冻结服务环境或取得账号权限。恢复页提供诊断复制，离线队列限量保留 7 天，服务器记录由维护任务按 30 天清理。

3.0.33 的 HTTPS 连通性预检不读取账号或切换环境，只用于等待本应用网络可用；任意合法 HTTP 响应均不等于商店认证通过。网络路径和前台通知只触发有界恢复，最终仍必须取得 Apple verified 凭据。诊断队列在预检、StoreKit 调用或应用非活跃期间暂停发送，恢复发送前等待验证退出。

开发签名 owner 包保留显式开关：

```sh
BLINDORACLE_SANDBOX=YES python3 Scripts/generate_project.py
# 使用 BlindOracle scheme 正常构建；Debug 与 Release 都会编译 BLINDORACLE_SANDBOX 条件。
# 构建完成后恢复仓库默认生产工程：
env -u BLINDORACLE_SANDBOX python3 Scripts/generate_project.py
```

仅向 `xcodebuild` 传同名用户设置不会替代工程生成开关。owner 包显示名「瞎子·测试」，Info 的 `OracleServiceEnvironmentResolution=OwnerSandbox`、`OracleServiceEnvironment=Sandbox`，仍受服务器 owner 白名单约束。默认发布工程为 `AppleVerified`、默认构建配置记录为 `Production`，名称为「瞎子」；实际路由由 Apple verified 证据决定，不能以该 metadata 推断当前账本。UserDefaults、发布版启动参数和账号响应不能切换已冻结环境。正式发布前检查没有 owner 沙盒 Swift 条件、`BLINDORACLE_SANDBOX=NO`，并以同一归档进行真实 TestFlight 验收。

生产继续使用原 `com.lihao.BlindOracle.wellecho.account` Keychain service、原任务目录及原结束队列；沙盒使用 `.sandbox` service 和独立文件名，失效标记随命名空间隔离。共享本机资料与历史不自动删除；沙盒也不会读取或清除生产登录。正常 Apple 账号用于 App 登录，Sandbox tester 仅用于系统购买，后台可限制测试登录白名单。沙盒删号不撤销 Apple 全局授权；生产删号流程保持原规则。

沙盒购买只接受 StoreKit 的 Sandbox 交易，生产只接受 Production。服务器独立验单并确认环境与账号归属，客户端仍严格校验商品币种及金额，不因测试而放宽。若商品已返回但币种或价格不匹配，应在系统「设置 → 开发者 → 沙盒 Apple 账户」登录中国大陆 tester 后刷新；App 不请求 tester 密码，也不自动切换系统购买账号。

发布前检查 Debug/Release 包均不含 `dev-key.txt`、`qwen-key.txt` 或其他供应商凭据资源。密钥轮换只在服务器执行；不能通过重新打包 App 分发供应商密钥。真实联网测试需要有效的自有账号会话，并受同一网关任务、额度和并发策略约束；Debug 合成夹具不代表真实授权或付款成功。

开发者门户需为 `com.lihao.BlindOracle` 开启 Sign in with Apple，签名描述文件必须包含 `com.apple.developer.applesignin`。`App/BlindOracle.entitlements` 与 `Scripts/generate_project.py` 共同保存工程配置。Apple 私钥、供应商 key、服务器环境变量只在服务端配置，不能放进 App、README、日志或测试夹具。

3.0.16 起启动必须先登录，已有会话经服务器验证后自动恢复；未登录时只提供登录和协议政策入口。退出会回到门禁，本机人员资料与聊天不随账号删除，但需重新登录后才能访问。请在删除账号前分别清理需要删除的本机数据/历史。
