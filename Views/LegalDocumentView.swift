import SwiftUI

enum LegalDocument {
    case userAgreement
    case privacyPolicy

    var title: String {
        switch self {
        case .userAgreement: return L10n.text("用户协议", "User Agreement")
        case .privacyPolicy: return L10n.text("隐私政策", "Privacy Policy")
        }
    }

    fileprivate var sections: [LegalSection] {
        switch self {
        case .userAgreement: return agreementSections
        case .privacyPolicy: return privacySections
        }
    }

    private var agreementSections: [LegalSection] {
        [
            LegalSection(
                title: L10n.text("一、协议与服务", "1. This agreement and the service"),
                text: L10n.text(
                    "本协议适用于个人开发者 lihao（以下简称「我们」）提供的「瞎子」应用，包括本地推演、AI 解读、对话、资料管理等功能。请在使用相关功能前阅读本协议和隐私政策。",
                    "This agreement covers BlindOracle, provided by the individual developer lihao (“we”), including its local readings, AI interpretations, conversations, and data management features. Please read this agreement and the Privacy Policy before using these features."
                )
            ),
            LegalSection(
                title: L10n.text("二、解读的用途与边界", "2. Purpose and limitations of readings"),
                text: L10n.text(
                    "本应用用于传统文化体验、娱乐和自我梳理。规则计算和 AI 输出可能存在错误、遗漏或虚构，直率或幽默的语气也不表示结论经过事实核实。解读无法保证未来事件、他人想法或关系走向。\n\n请结合现实信息独立判断，不应将解读作为医疗、法律、投资、人身安全或其他重大决定的依据。需要专业帮助时，请向相应专业人士求助。",
                    "BlindOracle is for exploring traditional practices, entertainment, and personal reflection. Calculations and AI responses may contain errors, omissions, or invented details. A direct or humorous tone does not establish factual accuracy. Readings cannot guarantee future events, another person’s thoughts, or the outcome of a relationship.\n\nUse real-world information and your own judgment. Do not rely on readings for medical, legal, investment, personal safety, or other consequential decisions. Seek qualified professional help when appropriate."
                )
            ),
            LegalSection(
                title: L10n.text("三、资料与合理使用", "3. Your information and responsible use"),
                text: L10n.text(
                    "你可以自行选择提供的资料，并使用「未知」选项处理不清楚的信息；部分推演需要特定资料才能完成。填写他人的姓名、出生资料、位置或对话内容前，请取得适当授权。请勿输入身份证号、银行卡号、密码等与推演无关的敏感信息。\n\n请依法使用本应用，尊重他人的隐私和知识产权，不得利用本应用实施欺诈、骚扰、侵权、违法活动或干扰服务运行。",
                    "You choose which information to provide and can mark information as unknown. Some readings require particular details to work. Obtain appropriate permission before entering someone else’s name, birth details, location, or conversations. Avoid entering unrelated sensitive information such as government identifiers, payment card numbers, or passwords.\n\nUse the app lawfully, respect privacy and intellectual property, and do not use it for fraud, harassment, infringement, illegal activities, or interference with the service."
                )
            ),
            LegalSection(
                title: L10n.text("四、AI 与第三方服务", "4. AI and third-party services"),
                text: L10n.text(
                    "联网功能使用应用提供的 AI 解读服务，相关数据发送范围见隐私政策。AI 服务的可用性、速度、输出和使用限制也受服务方规则影响。\n\n定位、地名解析及主动打开的外部链接适用相关服务方的条款。第三方服务中断或变更可能影响相应功能。",
                    "Online features use the AI interpretation service provided by the app. The Privacy Policy explains the information sent. Availability, speed, responses, and usage limits also depend on the service.\n\nLocation services, place lookup, and external links you choose to open are also subject to the relevant provider’s terms. Changes or interruptions to those services can affect these features."
                )
            ),
            LegalSection(
                title: L10n.text("五、额度与 App 内购买", "5. Credits and in-app purchases"),
                text: L10n.text(
                    "应用提供消耗型额度包，当前配置为人民币 6 元一包；可购买的商品与最终价格以付款前 App Store 展示为准。这不是 VIP 或订阅，没有自动续费。额度用于 AI 解读，按服务器可核实的实际输入和输出用量扣减，不重复计算已包含在输出中的推理用量。额度不设到期日，但使用仍受账号状态、服务可用性及合理的安全和用量限制影响。\n\n购买须由 Apple 和服务器核验后到账，同一笔交易只到账一次。额度绑定购买时登录的服务器账号，切换账号不会自动转移余额。补充额度会累加到现有剩余额度，并把到账后的合计剩余额度设为进度条的新 100%；这不表示恢复全部历史额度。首次成功 Apple 登录的赠额每个 Apple 身份仅一次，删除后重新注册不会重复获得。\n\n如付款后未到账，请先使用账号页的购买核对功能或联系支持，避免重复付款。退款申请由 Apple 受理和审核，是否获准及相关权利依适用规则处理；本协议不限制你的法定权利。收到可信退款信息后，服务器会冲正对应额度；若相关额度已消耗，可能留下待核对差额、限制新任务，并由后续付费到账额度先行抵扣。删除账号不等于申请退款，请在删除前核对剩余额度和未完成交易。",
                    "The app offers consumable credit packs, currently configured at CNY 6 per pack. Available products and the final price are shown by the App Store before payment. This is not a VIP plan or subscription, and there is no automatic renewal. Credits are used for AI readings and deducted based on verifiable actual input and output usage; reasoning usage already included in output is not counted twice. Credits have no expiry date, but use remains subject to account status, service availability, and reasonable security and usage limits.\n\nPurchases are credited after Apple and server verification, once per transaction. Credits belong to the server account signed in at purchase; switching accounts does not transfer the balance. Adding credits increases the existing balance and makes the combined remaining balance the progress bar’s new 100%; it does not restore all historical credits. The first successful Apple sign-in grant is available once per Apple identity. Deleting and registering again does not grant it again.\n\nIf payment succeeds but credits do not appear, use the account page’s purchase check or contact support before paying again. Apple receives and reviews refund requests; approval and related rights are governed by applicable rules. This agreement does not limit statutory rights. After receiving verified refund information, the server reverses the corresponding credits. If those credits have been used, a balance discrepancy may remain, new tasks may be restricted, and later paid credits may first offset that discrepancy. Deleting an account does not request a refund. Check remaining credits and unfinished transactions before deletion."
                )
            ),
            LegalSection(
                title: L10n.text("六、内容与知识产权", "6. Content and intellectual property"),
                text: L10n.text(
                    "你提供的内容所享有的权利不因使用本应用而转让给我们；为提供你请求的功能，应用会按隐私政策处理相关内容。分享解读时，请核查内容、保护相关人员的隐私，并说明其中包含 AI 生成内容。AI 输出的权利和使用限制还可能受适用法律及AI 服务方条款影响。\n\n应用程序、界面及第三方资料的权利归各自权利人所有。第三方资料的来源与许可可在设置中查看。通过 App Store 获得的应用许可遵循商店展示的适用许可条款；未提供自定义许可时，适用 Apple 标准最终用户许可协议。",
                    "Using the app does not transfer your rights in the content you provide to us. The app processes that content as described in the Privacy Policy to provide the features you request. Check readings, protect the privacy of those involved, and disclose any AI-generated content before sharing them. Rights in and restrictions on AI output may also depend on applicable law and the AI service’s terms.\n\nThe app, its interface, and third-party materials belong to their respective rights holders. Sources and licenses are available in Settings. Apps obtained through the App Store are subject to the applicable license shown there. Apple’s Standard End User License Agreement applies when no custom license is provided."
                )
            ),
            LegalSection(
                title: L10n.text("七、本地记录与服务可用性", "7. Local records and availability"),
                text: L10n.text(
                    "资料和记录主要保存在当前设备。记录保留、删除范围及既有数据副本的处理见隐私政策。设备损坏、存储不足、卸载、系统操作或测试版本到期可能影响记录访问或服务使用。\n\n我们会合理维护应用，但无法保证服务始终连续、无错误或适合所有用途。依法应由我们承担的责任，不因本条免除；你的法定权利不受本协议限制。",
                    "Profiles and records are primarily stored on your current device. The Privacy Policy describes record retention, deletion scope, and the handling of existing data copies. Device failure, insufficient storage, uninstallation, system actions, or expiry of a beta build can affect access to records or the service.\n\nWe will take reasonable care in maintaining the app, but cannot guarantee uninterrupted or error-free operation or suitability for every purpose. This provision does not exclude liability or limit rights that applicable law protects."
                )
            ),
            LegalSection(
                title: L10n.text("八、未成年人", "8. Minors"),
                text: L10n.text(
                    "未成年人应在监护人指导下阅读本协议和隐私政策、使用应用及处理个人信息。请避免向 AI 服务提交未成年人的敏感资料。监护人如发现相关信息被不当提供，可通过下方联系方式提出处理请求。",
                    "Minors should read this agreement and the Privacy Policy and use the app with guidance from a parent or guardian. Avoid submitting minors’ sensitive information to AI services. A parent or guardian who discovers inappropriate disclosure can contact us using the details below."
                )
            ),
            LegalSection(
                title: L10n.text("九、更新与争议处理", "9. Updates and resolving concerns"),
                text: L10n.text(
                    "服务或条款发生变化时，我们会更新本页面及更新日期。涉及依法需要另行告知或取得同意的事项，将按适用要求处理。你可以在设置底部随时查看当前文本。\n\n对应用或本协议有疑问时，请先联系我们协商解决。协商未果的，可依适用法律向有管辖权的机构寻求救济。本协议不排除你依法享有的消费者或个人信息保护权利。",
                    "When the service or these terms change, we will update this page and its revision date. Where applicable requirements call for a separate notice or consent, we will follow them. You can review the current text at the bottom of Settings.\n\nPlease contact us with concerns about the app or this agreement. If we cannot resolve them together, you may seek remedies from a competent authority under applicable law. This agreement does not exclude statutory consumer or data protection rights."
                )
            )
        ]
    }

    private var privacySections: [LegalSection] {
        [
            LegalSection(
                title: L10n.text("一、适用范围", "1. Scope"),
                text: L10n.text(
                    "本政策说明「瞎子」的个人开发者 lihao（以下简称「我们」）如何通过本应用处理信息，以及你可以如何管理这些信息。应用在设备本地保存资料，必须使用 Apple 登录后才能使用应用，包括在线解读、账号查询和本机资料访问。未登录时可查看用户协议与隐私政策。",
                    "This policy explains how lihao, the individual developer of BlindOracle (“we”), processes information through the app and how you can manage it. The app stores records on your device. Sign in with Apple to use the app, including online readings, account services and access to local records. The User Agreement and Privacy Policy remain available before signing in."
                )
            ),
            LegalSection(
                title: L10n.text("二、处理哪些信息及用途", "2. Information processed and its purposes"),
                text: L10n.text(
                    "你输入的问事、追问和回复会形成对话记录。你填写或选择的姓名或称呼、人物关系、出生日期和时间、历法、排盘性别、时区、出生地或当前地点及坐标，用于识别问事对象、计算和解读。应用也会保存推演结果、抽牌或起卦记录、对话摘要、尚未完成的表单与操作状态，以支持查看历史、继续对话和重试。\n\n应用在本机保存语言和解读风格设置。服务认证信息放入系统钥匙串，用于验证联网请求身份。即使未将某人另存为资料档案，已经用于对话或推演的信息仍可能包含在相关记录中。",
                    "Your questions, follow-ups, and responses become conversation records. Names or labels, relationships, birth dates and times, calendar choices, charting sex, time zones, birthplaces or current locations, and coordinates are used to identify participants and produce readings. The app also stores results, card draws or coin casts, conversation summaries, and unfinished forms and operations so you can review, continue, or retry them.\n\nLanguage and reading-style settings are stored on the device. Service credentials are stored in the system Keychain to authenticate online requests. Information used in a conversation or reading may remain in that record even if you do not separately save the person as a profile."
                )
            ),
            LegalSection(
                title: L10n.text("三、联网 AI 会接收什么", "3. Information sent to online AI"),
                text: L10n.text(
                    "联网 AI 的数据使用许可独立于 Apple 登录。首次向第三方 AI 发送前，应用会单独说明接收方、发送范围和用途，由你选择「同意并继续」或「暂不使用 AI」。不同意会保留草稿，仍可使用账号和本机资料。你可以随时在对话页右上角的「AI 数据使用」入口撤回许可，阻止后续发送；撤回不会自动撤销已发出的数据或进行中的任务，也不保证免扣已发生的用量。\n\n应用通过内置的 AI 解读服务处理联网请求。提交问题后，规划请求就可能发送问事原文、相关对话与摘要、当前资料、已保存人员的姓名或称呼及资料可用情况索引、待填表单和相关历史推演信息；这可能发生在问事单最终确认之前。\n\n生成解读和追问回复时，会按功能发送相关人员的资料快照（可能含姓名、出生资料、地点和坐标）、推演结果、牌面或爻值及上下文。整理长对话摘要也会发送需归纳的旧对话。切换到其他应用后，已经启动的分析可能继续。\n\n停止回答会停止本机继续接收和展示当前回答，但服务器可能继续完成已启动的任务，并按可核实的实际用量结算；停止接收不保证取消处理或免扣额度，已经发出的内容也无法收回。可恢复的完整回答会临时缓存，读取同一份缓存回答不会再次调用 AI 或重复扣费。未提交的问题和未确认发送的新消息不会发起新的解读请求。",
                    "Permission to share data with online AI is separate from Apple sign-in. Before the first transmission to third-party AI, the app separately explains the recipients, scope, and purpose, and lets you agree and continue or decline AI use. Declining keeps drafts and leaves account services and local records available. You can withdraw permission at any time through AI data use at the top right of Chat to prevent future transmissions. Withdrawal does not automatically undo data already sent or tasks in progress, and does not guarantee that usage already incurred will be waived.\n\nThe app uses its built-in AI interpretation service for online requests. Submitting a question can immediately send the question, relevant conversation and summaries, the current profile, a directory of saved people’s names or labels and available profile fields, pending forms, and relevant past readings for planning. This can happen before you finally confirm an intake form.\n\nInterpretations and follow-up replies send relevant participant snapshots, which may include names, birth details, places, and coordinates, along with results, cards or coin casts, and context. Summarizing a long conversation also sends the older messages being summarized. Analysis already started may continue when you switch to another app.\n\nStopping a reply stops this device from receiving and displaying the current response, but the server may finish a task already started and deduct credits for verifiable actual usage. Stopping reception does not guarantee cancellation or waive credit deductions, and content already sent cannot be recalled. Complete responses eligible for recovery are temporarily cached; retrieving the same cached response does not call the AI service again or deduct credits again. Questions and new messages that you have not submitted do not start a new interpretation request."
                )
            ),
            LegalSection(
                title: L10n.text("四、AI 服务方与第三方处理", "4. AI providers and third-party processing"),
                text: L10n.text(
                    "AI 解读请求通过 HTTPS 发送到我们在 wellecho.cn 提供的服务器，再转交 DeepSeek 开放平台的模型 API。我们的服务器因此会处理本次所需的问题、上下文、资料与回答，并记录账号、请求时间、状态和必要使用记录；服务器不持久保存原始问题正文，只保留请求指纹；为断线续传临时加密缓存完整回答，48 小时后不可重放并定时清理。数据库备份设有访问权限限制，采用 14 天轮换策略，备份文件本身未另行加密；临时回答以加密形式进入备份，可能到该备份轮换后才清除。AI 服务方会接收请求内容，并可能记录调用时间及用量等技术信息。\n\n第三方对请求和响应的保存、处理地区、删除及训练使用规则，取决于其现行政策和 API 账户约定。DeepSeek 可能依据适用条款留存请求和响应，并在去标识化等条件下用于优化服务或训练模型；具体规则见下方服务方条款。我们尚未核实本 API 账户适用的具体留存、处理地区及训练或优化安排，不承诺数据不会用于此类用途。请查阅下方服务方说明。删除本机记录不会删除已经向服务方发送的数据。如需处理服务方持有的信息，可通过其政策列明的渠道提出请求，也可联系我们协助。\n\n账号服务和官网还会记录 IP 地址、访问时间、请求路径、状态码、客户端或浏览器信息、来源页及响应大小，用于运行维护、排障和防止滥用。当前访问日志每日轮换，保留 10 份历史日志，另有正在写入的当前日志；清除随轮换执行。这里的日志不用于广告追踪。",
                    "AI interpretation requests are sent over HTTPS through our server at wellecho.cn to the DeepSeek Open Platform model API. Our server processes the question, context, profile information and response needed for that request and records the account, request time, status and necessary usage records. The server does not persist original question text; it retains request fingerprints. Full responses are temporarily encrypted for interrupted-request recovery, become unavailable for replay after 48 hours, and are cleared by scheduled cleanup. Database backups have restricted access and follow a 14-day rotation policy; the backup files themselves are not separately encrypted. Temporary responses enter backups in encrypted form and may remain until the relevant backup rotates out. The AI service receives request contents and may record technical request and usage information.\n\nRetention, processing locations, deletion, and any training use of requests and responses depend on the provider’s current policies and API account terms. Under applicable terms, DeepSeek may retain requests and responses and use them to improve services or train models subject to de-identification and other conditions. See the provider terms below. We have not verified the specific retention, processing-region, training, or optimization arrangements applicable to this API account and do not promise that data will be excluded from those uses. Review the provider information below. Deleting local records does not delete information already sent to the service. For information held by a provider, use the request channels described in its policy or contact us for assistance.\n\nThe account service and website also log IP addresses, access times, request paths, status codes, client or browser information, referrers, and response sizes for operations, troubleshooting, and abuse prevention. Access logs currently rotate daily, retaining 10 historical logs in addition to the active log; removal occurs through rotation. These logs are not used for advertising tracking."
                )
            ),
            LegalSection(
                title: L10n.text("五、定位与地区查询", "5. Location and place lookup"),
                text: L10n.text(
                    "主动点击「使用当前位置」时，应用会向系统申请使用期间的定位权限，获取设备位置，并通过 Apple 系统地理服务解析地点，再填写你选定的出生地或当前地点。地点和坐标可能进入自动保存的表单草稿、资料、推演及相关 AI 请求，部分处理可能早于最终确认。你可以拒绝定位、从地区列表选择地点，或在系统设置中撤回定位权限。\n\n地区列表主要使用内置数据。某个地区缺少坐标时，AI 解读服务可能接收该地区的名称和代码以辅助查询，Apple 系统地理服务会接收地名查询或位置。相关系统服务及其合作方按自身政策处理信息。",
                    "When you tap “Use current location,” the app requests location access while in use, obtains the device’s position, and uses Apple’s system geocoding services to fill your chosen birthplace or current location field. Places and coordinates may be included in automatically saved form drafts, profiles, readings, and related AI requests, including some processing before final confirmation. You can decline location access, choose from the place list, or revoke permission in system settings.\n\nThe place list mainly uses bundled data. If coordinates are missing, the AI interpretation service may receive the public district name and code to assist lookup, and Apple’s system geocoding services receive the place query or location. Those system services and their partners process information under their own policies."
                )
            ),
            LegalSection(
                title: L10n.text("六、本机存储与安全", "6. On-device storage and security"),
                text: L10n.text(
                    "资料、对话、推演、摘要和未完成状态保存在应用的本机目录，使用系统提供的文件保护。账号会话凭证使用仅限本机的系统钥匙串保存，AI 服务方的密钥只保存在服务器。应用将资料目录标记为排除系统自动备份，并未提供自有服务器的档案云同步功能。请妥善保护设备和解锁凭据。\n\n当前应用未集成广告追踪或第三方行为分析 SDK。Apple 的系统诊断、TestFlight 的测试反馈及服务方的技术记录依其规则处理。通过 TestFlight 主动发送的反馈及附图会提供给开发者和 Apple，请留意其中是否包含个人信息。",
                    "Profiles, conversations, readings, summaries, and unfinished work are stored in the app’s local directory using system file protection. Account session credentials are stored in a device-only system Keychain; AI provider keys stay on the server. The app marks its data directory as excluded from automatic system backup and currently provides no profile cloud synchronization through a developer-operated server. Protect your device and its unlock credentials.\n\nThe current app integrates no advertising tracking or third-party behavioral analytics SDK. Apple’s system diagnostics, TestFlight feedback, and providers’ technical records follow their respective rules. Feedback and screenshots you choose to send through TestFlight are provided to the developer and Apple, so check them for personal information."
                )
            ),
            LegalSection(
                title: L10n.text("七、保留与删除范围", "7. Retention and deletion scope"),
                text: L10n.text(
                    "本机记录通常保留到你删除相关记录或应用数据。你可以在数据页修改或删除资料、删除推演，在历史列表删除对话或清除全部历史。清除全部历史会清除聊天及未完成的表单和操作进度，人员资料与已保存的推演记录会保留。删除某份资料不会自动清除它在旧对话、旧推演中的内容；删除推演也不会自动删除对话文字。\n\n服务器保留与账号 UUID 关联的钱包、购买、退款、额度流水和用量元数据，用于提供服务、核对账务和处理异常；还保留 Apple 身份的带密钥防重摘要，防止删除后重新领取赠额。测试环境另保留商店安装凭证与登录身份的带密钥绑定摘要。摘要不保存对应凭证或 Apple 身份原文，但连同账号和账务记录仍属于去标识化记录，并非完全匿名。上述账务、计量及防重记录目前没有统一固定的自动删除期限；你可联系我们提出相关信息请求，我们会核实仍需保留的范围及可处理的部分。\n\n删除本机记录不会删除已分享的文件、服务器留存记录或 AI 服务方保存的内容。卸载应用通常移除其本机资料，但系统钥匙串中的服务认证信息可能保留。",
                    "Local records are generally retained until you delete the relevant records or app data. You can edit or delete profiles and readings in Data, and delete individual conversations or clear all history in History. Clearing all history removes chats and unfinished forms or operations while keeping profiles and saved readings. Deleting a profile does not automatically remove its contents from older conversations or reading snapshots. Deleting a reading does not automatically remove the conversation text.\n\nThe server retains wallet, purchase, refund, credit-ledger, and usage metadata linked to the account UUID to provide the service, reconcile accounts, and resolve issues. It also retains a keyed digest of the Apple identity to prevent repeated welcome grants after deletion. The test environment additionally retains keyed digests binding a store-installation proof to a sign-in identity. These digests do not store the corresponding proof or Apple identity in plain text, but together with account and accounting records they remain pseudonymous, not fully anonymous. These accounting, usage, and abuse-prevention records currently have no single fixed automatic deletion period. Contact us with a request about your information so we can verify what still needs to be retained and what can be addressed.\n\nDeleting local records does not delete shared files, records retained on the server, or information retained by an AI provider. Uninstalling the app normally removes local app data, but service credentials in the system Keychain may remain."
                )
            ),
            LegalSection(
                title: L10n.text("八、你的选择与信息请求", "8. Your choices and information requests"),
                text: L10n.text(
                    "你可以查看和编辑资料、删除相应记录、清除聊天历史，以及在系统设置中管理定位权限。停止回答或撤回权限后，已完成的必要处理和已发出的请求不会自动撤销。\n\n如需查询、更正、复制、删除相关个人信息，或对处理方式提出意见，请通过下方方式联系我们。为核实请求，我们只会要求与请求相关的必要信息。Apple 登录会将身份凭证、Apple 提供的姓名或邮箱（可能是隐藏邮箱）发送到 wellecho.cn。服务器保存账号 UUID、Apple 身份标识、姓名或邮箱、加密授权凭据及会话摘要，以建立账号和验证访问。购买还保存商品、交易标识、金额币种、核验与退款状态；不会取得你的银行卡或完整付款账户资料。\n\n在「数据 → 账号」选择「删除账号」并确认后，服务器会清除该账号的姓名、邮箱、Apple 身份关联与授权凭据，删除登录会话，停用账号，取消未完成任务并清除在线回答缓存；保留前节说明的 UUID 关联账务、计量及防重摘要。正式环境还会撤销已知 Apple 登录授权；测试环境不撤销共享的 Apple 授权，以免影响正式账号。备份中的既有副本随备份轮换处理。删除账号不自动退款，也不会把原账号余额自动恢复到新注册账号。\n\n本机资料独立于账号，退出、切换或删除账号不自动删除或隔离本机记录；重新登录后仍可访问当前设备上的记录。请在删除账号前先清理需要删除的本机数据，相关操作需要你在设备上完成。",
                    "You can view and edit profiles, delete records, clear chat history, and manage location permission in system settings. Stopping a reply or revoking permission does not automatically reverse completed processing or requests already sent.\n\nContact us below to request access, correction, a copy, or deletion of relevant personal information, or to raise a concern. We will request only information necessary to verify and address your request. Sign in with Apple sends identity credentials and the name or email Apple provides, which may be a private relay address, to wellecho.cn. The server stores the account UUID, Apple identity identifier, name or email, encrypted authorization credentials, and session digests to establish accounts and authenticate access. Purchases additionally retain product and transaction identifiers, amount and currency, and verification and refund status. We do not obtain your bank card or full payment-account details.\n\nIn Data → Account, choose Delete account and confirm. The server removes that account’s name, email, Apple identity link, authorization credentials, and sign-in sessions; disables the account; cancels unfinished tasks; and clears online response caches. UUID-linked accounting, usage, and abuse-prevention digests described above remain. The production environment also revokes known Apple sign-in grants. The test environment preserves the shared Apple grant to avoid affecting the production account. Existing copies in backups are handled through backup rotation. Account deletion does not automatically request a refund or restore the old balance to a newly registered account.\n\nLocal records are independent of accounts. Signing out, switching or deleting an account does not automatically delete or separate local records. Signing in again restores access to this device’s records. Remove local data on the device before deleting your account if needed."
                )
            ),
            LegalSection(
                title: L10n.text("九、未成年人及他人资料", "9. Minors and other people’s information"),
                text: L10n.text(
                    "请在获得适当授权后填写他人的资料。未成年人应由监护人指导使用，避免向 AI 提交其敏感信息。如果你或监护人发现相关个人信息被不当提供，请联系我们，我们会结合本机存储和第三方处理的实际情况协助处理。",
                    "Obtain appropriate permission before entering someone else’s information. Minors should use the app with guidance from a parent or guardian and avoid submitting sensitive information to AI. If you or a guardian discover inappropriate disclosure, contact us so we can help address it within the scope of local storage and third-party processing."
                )
            ),
            LegalSection(
                title: L10n.text("十、政策更新", "10. Policy updates"),
                text: L10n.text(
                    "我们会根据功能及信息处理方式的变化更新本政策，并标明更新日期。依法需要额外告知或单独取得同意的事项，将按适用要求处理。当前版本可随时从设置底部查看。",
                    "We will update this policy and its revision date when features or information handling change. We will follow applicable requirements for additional notice or separate consent. The current version is always available at the bottom of Settings."
                )
            )
        ]
    }
}

private struct LegalSection {
    let title: String
    let text: String
}

struct LegalDocumentView: View {
    let document: LegalDocument

    var body: some View {
        ZStack {
            PaperBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text(L10n.text("更新日期 2026年11月7日", "Updated November 7, 2026"))
                        .font(.footnote)
                        .foregroundStyle(InkTheme.secondary)
                    ForEach(document.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title)
                                .font(.system(.headline, design: .serif))
                                .accessibilityAddTraits(.isHeader)
                            Text(section.text)
                                .font(.system(.body, design: .serif))
                                .lineSpacing(6)
                        }
                    }
                    if case .privacyPolicy = document {
                        providerPolicies
                    } else {
                        Link(L10n.text("Apple 标准最终用户许可协议", "Apple Standard End User License Agreement"),
                             destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                            .font(.system(.body, design: .serif))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.text("联系我们", "Contact us"))
                            .font(.system(.headline, design: .serif))
                            .accessibilityAddTraits(.isHeader)
                        Text(L10n.text("个人开发者 lihao · 联系人 李浩", "Individual developer lihao · Contact lihao"))
                            .font(.system(.body, design: .serif))
                        Link("2114581274@qq.com", destination: URL(string: "mailto:2114581274@qq.com")!)
                            .font(.system(.body, design: .serif))
                            .accessibilityIdentifier("legalContactEmail")
                        Text(L10n.text(
                            "有关本应用、协议或个人信息处理的问题及权利请求，请通过上述邮箱联系我们。我们会使用你的邮箱和来信内容核实并处理请求。邮件中请勿附带 API 密钥或与请求无关的敏感资料。",
                            "For questions about the app, these terms, information handling, or requests about your information, contact us at the email address above. We use your email address and message to verify and address your request. Do not include API keys or unrelated sensitive information."
                        ))
                        .font(.system(.body, design: .serif))
                        .lineSpacing(6)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("legalDocumentContact")
                }
                .foregroundStyle(InkTheme.ink)
                .textSelection(.enabled)
                .padding(22)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("legalDocumentScroll")
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .tint(InkTheme.cinnabar)
    }

    private var providerPolicies: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("第三方服务说明", "Third-party policies"))
                .font(.system(.headline, design: .serif))
                .accessibilityAddTraits(.isHeader)
            Link(L10n.text("DeepSeek 开放平台服务条款", "DeepSeek Open Platform terms"), destination: URL(string: AppLanguage.current.isEnglish
                ? "https://cdn.deepseek.com/policies/en-US/deepseek-open-platform-terms-of-service.html"
                : "https://cdn.deepseek.com/policies/zh-CN/deepseek-open-platform-terms-of-service.html")!)
            Link(L10n.text("DeepSeek 用户协议（含训练与优化说明）", "DeepSeek Terms of Use (training and optimization)"), destination: URL(string: AppLanguage.current.isEnglish
                ? "https://cdn.deepseek.com/policies/en-US/deepseek-terms-of-use.html"
                : "https://cdn.deepseek.com/policies/zh-CN/deepseek-terms-of-use.html")!)
            Link(L10n.text("Apple 地图与隐私", "Apple Maps and Privacy"), destination: URL(string: AppLanguage.current.isEnglish
                ? "https://www.apple.com/legal/privacy/data/en/apple-maps/"
                : "https://www.apple.com/legal/privacy/data/zh-cn/apple-maps/")!)
            Text(L10n.text("以上链接将联网打开服务方网站。", "These links open the providers’ websites online."))
                .font(.footnote)
                .foregroundStyle(InkTheme.secondary)
        }
        .font(.system(.body, design: .serif))
    }
}
