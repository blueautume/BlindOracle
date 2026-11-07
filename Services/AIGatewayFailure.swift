import Foundation

/// Only known machine codes select app-owned copy. Server messages, HTML and
/// provider response text never become a user-facing error.
enum AIGatewayFailure {
    static let maximumBodyBytes = 8_192

    static func error(status: Int, body: Data) -> DeepSeekError {
        guard body.count < maximumBodyBytes,
              let code = try? JSONDecoder().decode(Envelope.self, from: body).error.code else {
            return .http(status)
        }
        return error(status: status, code: code)
    }

    static func error(status: Int, code: String) -> DeepSeekError {
        guard kind(status: status, code: code) != nil else { return .http(status) }
        return .gateway(status: status, code: code)
    }

    static func message(status: Int, code: String) -> String? {
        guard let kind = kind(status: status, code: code) else { return nil }
        switch kind {
        case .dailyLimit:
            return L10n.text("今日服务使用已达上限，请明天再试。账户剩余额度会保留。", "You’ve reached today’s service limit. Try again tomorrow. Your remaining allowance is preserved.")
        case .globalDailyLimit:
            return L10n.text("今日解读服务已达临时上限，请明天再试。账户剩余额度会保留。", "The reading service has reached its temporary daily limit. Try again tomorrow. Your remaining allowance is preserved.")
        case .busy:
            return L10n.text("当前使用人数较多，请稍后再试。账户剩余额度会保留。", "The service is handling many requests. Try again shortly. Your remaining allowance is preserved.")
        case .running:
            return L10n.text("你还有一份回答正在生成，请等它完成后再继续。", "One of your replies is still being generated. Wait for it to finish before continuing.")
        case .connectionRetries:
            return L10n.text("最近几次连接连续遇到异常，请稍候再重试。原问事和剩余额度会保留。", "Several recent connections failed. Wait a little before retrying. Your reading and remaining allowance are preserved.")
        case .stageRetries:
            return L10n.text("这一步重试较多，请稍后再试。原问事和剩余额度会保留。", "This step has been retried several times. Try again later. Your reading and remaining allowance are preserved.")
        case .taskSteps:
            return L10n.text("这次问事的准备步骤已达上限，请重新发起问事。已填写的资料和原记录会保留。", "This reading has reached its preparation limit. Start a new reading. Your entered details and existing records are saved.")
        case .upstreamUnavailable:
            return L10n.text("解读服务暂时无法接收请求，请稍后重试。原问事会保留。", "The reading service can’t accept this request right now. Try again shortly. Your reading is saved.")
        case .interrupted:
            return L10n.text("回答传送中断，请重试继续。已确认的资料和推演结果会保留。", "The reply was interrupted. Retry to continue. Your confirmed details and reading results are saved.")
        case .signIn:
            return L10n.text("登录状态已过期，请重新登录后再试。", "Your sign-in has expired. Sign in again and retry.")
        case .allowance:
            return L10n.text("当前额度已用完，请在数据页补充额度后开始新的问事。", "Your allowance is used up. Replenish it in Data before starting a new reading.")
        case .refund:
            return L10n.text("账户额度存在待处理调整，请补充额度或联系支持后再试。", "Your allowance has a pending adjustment. Replenish it or contact support before retrying.")
        case .account:
            return L10n.text("当前账户暂时无法使用服务，请联系支持。", "This account can’t use the service right now. Please contact support.")
        case .request:
            return L10n.text("这次请求暂时无法处理，请重新打开 App 后重试。已填写的资料会保留。", "This request couldn’t be processed. Reopen the app and retry. Your entered details are saved.")
        case .context:
            return L10n.text("这段对话较长，请开始新对话后再试。已有记录会保留。", "This conversation is too long. Start a new conversation and try again. Your existing records are saved.")
        case .update:
            return L10n.text("请先更新 App，再继续使用解读服务。", "Update the app before continuing to use the reading service.")
        case .conflict:
            return L10n.text("这次请求的信息已发生变化，请重新发起问事。原记录会保留。", "The details of this request have changed. Start a new reading. Your existing records are saved.")
        case .closed:
            return L10n.text("这次问事已结束，请发起新的问事。原记录会保留。", "This reading has ended. Start a new reading. Your existing records are saved.")
        }
    }

    private struct Envelope: Decodable {
        struct Detail: Decodable { let code: String }
        let error: Detail
    }

    private enum Kind {
        case dailyLimit, globalDailyLimit, busy, running, connectionRetries, stageRetries, taskSteps
        case upstreamUnavailable, interrupted, signIn, allowance, refund, account
        case request, context, update, conflict, closed
    }

    private static func kind(status: Int, code: String) -> Kind? {
        guard !code.isEmpty, code.utf8.count <= 80 else { return nil }
        switch (status, code) {
        case (429, "daily_budget"), (429, "daily_limit"), (429, "task_service_limit"): return .dailyLimit
        case (429, "global_daily_budget"): return .globalDailyLimit
        case (429, "service_busy"), (429, "throttled"): return .busy
        case (429, "generation_in_progress"), (409, "stage_running"), (409, "task_running"): return .running
        case (429, "service_retry_limit"): return .connectionRetries
        case (429, "stage_retry_limit"), (429, "stage_repair_limit"): return .stageRetries
        case (429, "task_stage_limit"): return .taskSteps
        case (429, "upstream_rejected"), (502, "upstream_rejected"), (502, "upstream_unavailable"),
             (503, "service_not_configured"), (503, "cache_not_configured"), (503, "response_cache_unavailable"):
            return .upstreamUnavailable
        case (502, "upstream_interrupted"), (502, "gateway_interrupted"), (502, "worker_interrupted"),
             (503, "settlement_unavailable"): return .interrupted
        case (401, "authentication_required"), (401, "not_authenticated"), (401, "authentication_failed"):
            return .signIn
        case (402, "quota_exhausted"): return .allowance
        case (402, "refund_debt"): return .refund
        case (403, "account_disabled"): return .account
        case (400, "invalid_body"), (400, "invalid_messages"), (400, "invalid_json"),
             (400, "invalid_purpose"), (400, "model_not_allowed"), (400, "invalid_budget"),
             (400, "invalid_request_id"), (400, "invalid_task_id"), (400, "invalid_stage_id"),
             (400, "invalid_fingerprint"), (400, "invalid_repair"):
            return .request
        case (413, "context_too_large"): return .context
        case (426, "update_required"): return .update
        case (409, "idempotency_conflict"), (409, "stage_payload_conflict"), (409, "task_final_stage_exists"):
            return .conflict
        case (410, "task_closed"): return .closed
        default: return nil
        }
    }
}
