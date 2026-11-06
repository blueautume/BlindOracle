# App Store 凭据恢复修复 · 3.0.21 / 47

3.0.20/46 真实 TestFlight 验收未通过：用户安装后停留在「暂时无法确认购买环境，请重试」启动页，尚未构建账号与 AI 服务。原实现将错误和未验证结果合并，恢复按钮仅再次读取 `AppTransaction.shared`，缺少 Apple 文档建议的显式刷新恢复路径。截图不能确定底层 StoreKit 错误码，不将其归因于账号服务器或备案拦截。

本版启动仍只读取 shared；用户明确点击「重新验证 App Store」才调用 `AppTransaction.refresh()`，系统可能要求验证商店账号。刷新与初始读取使用同一签名、Bundle ID、环境和非空凭据校验，并共享并发与冻结保护。取消、离线和验签失败均不创建服务、不切换账本、不清除历史。恢复页给出区分原因的提示与不含身份或凭据的验证代码。

本版已重新运行 499 项默认非 live 单元测试和 5 项账号 UI 测试，均通过；16 项环境与刷新策略聚焦测试也通过（它们包含在默认单元测试中，不能重复累计为不同用例）。日志与结果包分别为 `build/review-3.0.21-47-unit.*`、`build/review-3.0.21-47-ui.*`、`build/review-bootstrap-3.0.21-47.*`。没有重新运行 3.0.20 的后端或本地原生购买测试，相关历史证据保留其实际版本。

`build/review-archive-3.0.21-47/BlindOracle.xcarchive` 归档成功；导出的 `Export-internal/瞎子.ipa` 通过独立发行签名、AppleVerified 配置、版本、登录权限与无密钥/测试资产检查。归档中间产物保留 Xcode 开发签名，最终 IPA 的发行签名与 `get-task-allow=false` 单独验证，详见同目录 `candidate-verification.json`。本次仅上传内部 TestFlight，上传成功且 App Store Connect 已显示 47「内部 / 正在测试」，群组 blind；上传记录在同目录 `internal-upload-verification.json`，未提交 App Store 审核或公开发布。

用户已确认从 TestFlight 更新 47 后成功进入并显示「测试环境 · 购买不扣款」，随后完成一次模拟购买并显示「额度已补充」。只读设备元数据确认 3.0.21/47；服务器同期记录沙盒 Apple 登录及账号、钱包、用量读取成功，正式服务未新增会话或订单。首次入账核对恰新增一笔 Sandbox 订单、一条验证记录及一条 1,000,000 额度流水，数量 1、币种 CNY、签名金额 6 元（字段值 6000，单位为元的千分之一）均匹配，Production 财务未变。证据：`../OracleBackend/.secrets/deploy/review-3.0.21-testflight-first-purchase-verification.json`（600 权限）。

进入成功证明环境识别可用；用户没有说明是否点过刷新按钮，因此不以此断言旧版底层错误原因或本次刷新实际触发情况。当前账号走 owner 兼容路径，不能代替非 owner HTTP 登录、proof 原子绑定和新账号额度的真实验收。用户另已确认资料体积变化来自主动清理或重装，符合预期；不再将其作为本次数据丢失问题。

同一笔新 Sandbox 订单已通过两次官方查单与两次真实入账函数重复处理：两次均返回原订单，余额、流水、订单和验证记录均不增加；短事务强制回滚兜底，事务外两环境财务未变。额外通过官方 API 取得真实 AppTransaction，签名、环境、应用及 proof 字段解析兼容检查通过，未创建或绑定 proof、会话或赠额；这项不等于非 owner 的完整登录验收。只读与受控回滚验证证据为 `../OracleBackend/.secrets/deploy/review-3.0.21-testflight-idempotency-and-apptransaction.json`（600 权限）。

## 历史：审核与购买验收 · 3.0.20 / 46

## 环境合同

默认发布工程的 `OracleServiceEnvironmentResolution=AppleVerified`；`OracleServiceEnvironment=Production` 仅记录默认构建配置，不是运行时路由决定。启动先读取 `AppTransaction.shared`，只接受 Apple verified、匹配 Bundle ID 的 Production/Sandbox。路由冻结后才创建会话、AI、钱包和任务对象；unknown/Xcode、错误签名、错误应用和取凭据失败只显示恢复重试页，不读取另一套账号、不自动调用会弹商店认证的 refresh。

自动 Sandbox 登录携带 signed AppTransaction，由独立 Sandbox 后端再次验签。非 owner 不再依赖人工添加审核账号名单；其 proof 原子绑定稳定 Apple 登录摘要。两套数据库、会话与任务目录继续隔离，正式服务不能发放测试额度。AppTransaction 是下载/环境证明，不等同 Sign in with Apple 身份或 App Attest。稳定 appTransactionId 可防跨身份复用；旧系统 nonce fallback 与首次抢绑仍受访问开关、限流和 Sandbox 全局预算约束。

`BLINDORACLE_SANDBOX=YES` 仅用于开发签名 owner 包，`OwnerSandbox` 模式沿用白名单。此包不能证明发布包的下载凭据可用；开发签名安装未必有 App Store AppTransaction。

## 自动化范围

- 纯策略与启动测试：双环境、错误签名/应用/环境、缺凭据、失败重试、单飞、冻结后不能变更、登录 proof 与服务路由隔离。
- 客户端故障注入：取消、等待审批、丢失验单响应、重启重放、错误交易响应、已退款确认、账号切换、重复点击、金额/币种错误；服务端确认前禁止 finish。
- Apple 本地 StoreKitTest：本地 CNY 6 消耗商品、取消、等待审批、购买中断与恢复；Xcode 签名交易只能停在本地，不得提交真实后端或进入钱包。Fixture 仅复制到测试 bundle。
- PostgreSQL：账号、钱包、购买、退款、任务、并发与 Sandbox proof 绑定。网络模拟与真实 Server API 验单证据分开记录。

## 同一归档的真实分发验收（待完成）

Apple 明确 TestFlight 和审核内购使用 Sandbox；自动 AppTransaction 路由仍须通过真实分发验收，不以本地 `.storekit` 或 owner 包代替。

1. 从默认生成工程归档，核对 Bundle ID、3.0.20/46、AppleVerified、签名、无 provider key/p8/StoreKit fixture；名称保持「瞎子」。
2. 仅在得到上传授权后将该归档用于内部 TestFlight，不自动提交 App Review 或公开发布。
3. 使用非 owner 的正常 Apple 登录身份，从 TestFlight 启动；确认显示 Sandbox 标识并访问独立 Sandbox 后台。不得人工伪造凭据或关闭验签以通过。
4. 核对 `com.lihao.BlindOracle.quota.1m` 真实商品、CNY 6 显示与交付。当前只支持中国大陆 storefront，审核备注需写明。
5. 模拟取消、购买中断、完成付款后断网、服务器已入账但未确认、切后台/杀进程再启动。核对同一交易始终仅一笔订单和一次发额；其他登录身份不能交付该单。
6. 测试少量余额下的最后完整任务、重试与下一问题拦截。正式与 Sandbox 用量和账本不能互通。

## 备案放行后（待完成）

重新验证外网 HTTPS、官方 TEST、真实 Sandbox 退款、退款撤销及订单/账本对账。官方 TEST 成功只验证通知连通性，不代替真实业务通知或审核版本验收。内购通知是可选配置，但退款和异常补单需要可靠同步。

## 官方依据

- [审核使用 Sandbox](https://developer.apple.com/help/app-review/before-submitting-for-review/configure-in-app-purchases)
- [StoreKit 验证结果](https://developer.apple.com/documentation/storekit/verificationresult)
- [AppTransaction 刷新需用户操作](https://developer.apple.com/documentation/storekit/apptransaction/refresh())
- [App Store Server Library](https://github.com/apple/app-store-server-library-python)
