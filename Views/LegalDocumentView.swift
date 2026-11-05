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
                title: L10n.text("五、内容与知识产权", "5. Content and intellectual property"),
                text: L10n.text(
                    "你提供的内容所享有的权利不因使用本应用而转让给我们；为提供你请求的功能，应用会按隐私政策处理相关内容。分享解读时，请核查内容、保护相关人员的隐私，并说明其中包含 AI 生成内容。AI 输出的权利和使用限制还可能受适用法律及AI 服务方条款影响。\n\n应用程序、界面及第三方资料的权利归各自权利人所有。第三方资料的来源与许可可在设置中查看。通过 App Store 获得的应用许可遵循商店展示的适用许可条款；未提供自定义许可时，适用 Apple 标准最终用户许可协议。",
                    "Using the app does not transfer your rights in the content you provide to us. The app processes that content as described in the Privacy Policy to provide the features you request. Check readings, protect the privacy of those involved, and disclose any AI-generated content before sharing them. Rights in and restrictions on AI output may also depend on applicable law and the AI service’s terms.\n\nThe app, its interface, and third-party materials belong to their respective rights holders. Sources and licenses are available in Settings. Apps obtained through the App Store are subject to the applicable license shown there. Apple’s Standard End User License Agreement applies when no custom license is provided."
                )
            ),
            LegalSection(
                title: L10n.text("六、本地记录与服务可用性", "6. Local records and availability"),
                text: L10n.text(
                    "资料和记录主要保存在当前设备。请根据需要通过设置主动导出备份，并妥善保管。导出内容、删除记录的范围及数据副本的处理见隐私政策。设备损坏、存储不足、卸载、系统操作或测试版本到期可能影响记录访问或服务使用。\n\n我们会合理维护应用，但无法保证服务始终连续、无错误或适合所有用途。依法应由我们承担的责任，不因本条免除；你的法定权利不受本协议限制。",
                    "Profiles and records are primarily stored on your current device. Export a backup from Settings when needed and keep it secure. The Privacy Policy describes what exports contain and the scope of deletion. Device failure, insufficient storage, uninstallation, system actions, or expiry of a beta build can affect access to records or the service.\n\nWe will take reasonable care in maintaining the app, but cannot guarantee uninterrupted or error-free operation or suitability for every purpose. This provision does not exclude liability or limit rights that applicable law protects."
                )
            ),
            LegalSection(
                title: L10n.text("七、未成年人", "7. Minors"),
                text: L10n.text(
                    "未成年人应在监护人指导下阅读本协议和隐私政策、使用应用及处理个人信息。请避免向 AI 服务提交未成年人的敏感资料。监护人如发现相关信息被不当提供，可通过下方联系方式提出处理请求。",
                    "Minors should read this agreement and the Privacy Policy and use the app with guidance from a parent or guardian. Avoid submitting minors’ sensitive information to AI services. A parent or guardian who discovers inappropriate disclosure can contact us using the details below."
                )
            ),
            LegalSection(
                title: L10n.text("八、更新与争议处理", "8. Updates and resolving concerns"),
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
                    "本政策说明「瞎子」的个人开发者 lihao（以下简称「我们」）如何通过本应用处理信息，以及你可以如何管理这些信息。应用目前无需注册账户，主要在设备本地保存资料，并按你使用的功能调用 AI 解读服务和系统地理服务。",
                    "This policy explains how lihao, the individual developer of BlindOracle (“we”), processes information through the app and how you can manage it. The app currently requires no account registration. It primarily stores records on your device and calls the AI interpretation service and system geocoding services when those features are used."
                )
            ),
            LegalSection(
                title: L10n.text("二、处理哪些信息及用途", "2. Information processed and its purposes"),
                text: L10n.text(
                    "你输入的问事、追问和回复会形成对话记录。你填写或选择的姓名或称呼、人物关系、出生日期和时间、历法、排盘性别、时区、出生地或当前地点及坐标，用于识别问事对象、计算和解读。应用也会保存推演结果、抽牌或起卦记录、对话摘要、尚未完成的表单与操作状态，以支持查看历史、继续对话和重试。\n\n应用在本机保存语言、解读风格及解读偏好。服务认证信息放入系统钥匙串，用于验证联网请求身份。即使未将某人另存为资料档案，已经用于对话或推演的信息仍可能包含在相关记录中。",
                    "Your questions, follow-ups, and responses become conversation records. Names or labels, relationships, birth dates and times, calendar choices, charting sex, time zones, birthplaces or current locations, and coordinates are used to identify participants and produce readings. The app also stores results, card draws or coin casts, conversation summaries, and unfinished forms and operations so you can review, continue, or retry them.\n\nLanguage, reading style, and interpretation preferences are stored on the device. Service credentials are stored in the system Keychain to authenticate online requests. Information used in a conversation or reading may remain in that record even if you do not separately save the person as a profile."
                )
            ),
            LegalSection(
                title: L10n.text("三、联网 AI 会接收什么", "3. Information sent to online AI"),
                text: L10n.text(
                    "应用通过内置的 AI 解读服务处理联网请求。提交问题后，规划请求就可能发送问事原文、相关对话与摘要、当前资料、已保存人员的姓名或称呼及资料可用情况索引、待填表单和相关历史推演信息；这可能发生在问事单最终确认之前。\n\n生成解读和追问回复时，会按功能发送相关人员的资料快照（可能含姓名、出生资料、地点和坐标）、推演结果、牌面或爻值、解读偏好及上下文。整理长对话摘要也会发送需归纳的旧对话。切换到其他应用后，已经启动的分析可能继续。\n\n停止回答可取消当前请求，但已经发出的内容无法收回。未提交的问题和未确认发送的新消息不会发起新的解读请求。",
                    "The app uses its built-in AI interpretation service for online requests. Submitting a question can immediately send the question, relevant conversation and summaries, the current profile, a directory of saved people’s names or labels and available profile fields, pending forms, and relevant past readings for planning. This can happen before you finally confirm an intake form.\n\nInterpretations and follow-up replies send relevant participant snapshots, which may include names, birth details, places, and coordinates, along with results, cards or coin casts, preferences, and context. Summarizing a long conversation also sends the older messages being summarized. Analysis already started may continue when you switch to another app.\n\nStopping a reply cancels the current request but cannot recall content already sent. Questions and new messages that you have not submitted do not start a new interpretation request."
                )
            ),
            LegalSection(
                title: L10n.text("四、AI 服务方与第三方处理", "4. AI providers and third-party processing"),
                text: L10n.text(
                    "AI 解读请求通过 HTTPS 直接发送给提供解读能力的服务方，并携带服务认证信息。服务方会接收请求内容，并可能记录 IP 地址、调用时间及用量等技术信息。\n\n第三方对请求和响应的保存、处理地区、删除及训练使用规则，取决于其现行政策和 API 账户约定。请查阅下方服务方说明。删除本机记录不会删除已经向服务方发送的数据。如需处理服务方持有的信息，可通过其政策列明的渠道提出请求，也可联系我们协助。",
                    "AI interpretation requests are sent directly to the service over HTTPS with service credentials. The service receives the request contents and may record technical information such as IP addresses, request times, and usage.\n\nRetention, processing locations, deletion, and any training use of requests and responses depend on the provider’s current policies and API account terms. Review the provider information below. Deleting local records does not delete information already sent to the service. For information held by a provider, use the request channels described in its policy or contact us for assistance."
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
                    "资料、对话、推演、摘要和未完成状态保存在应用的本机目录，使用系统提供的文件保护。密钥使用仅限本机的系统钥匙串保存。应用将资料目录标记为排除系统自动备份，并未提供自有服务器的档案云同步功能。请妥善保护设备和解锁凭据。\n\n当前应用未集成广告追踪或第三方行为分析 SDK。Apple 的系统诊断、TestFlight 的测试反馈及服务方的技术记录依其规则处理。通过 TestFlight 主动发送的反馈及附图会提供给开发者和 Apple，请留意其中是否包含个人信息。",
                    "Profiles, conversations, readings, summaries, and unfinished work are stored in the app’s local directory using system file protection. Keys are stored in a device-only system Keychain. The app marks its data directory as excluded from automatic system backup and currently provides no profile cloud synchronization through a developer-operated server. Protect your device and its unlock credentials.\n\nThe current app integrates no advertising tracking or third-party behavioral analytics SDK. Apple’s system diagnostics, TestFlight feedback, and providers’ technical records follow their respective rules. Feedback and screenshots you choose to send through TestFlight are provided to the developer and Apple, so check them for personal information."
                )
            ),
            LegalSection(
                title: L10n.text("七、备份、保留与删除范围", "7. Backups, retention, and deletion scope"),
                text: L10n.text(
                    "本机记录通常保留到你删除相关记录或应用数据。你可以在数据页修改或删除资料、删除推演，在历史列表删除对话或清除全部历史。清除全部历史会清除聊天及未完成的表单和操作进度，人员资料与已保存的推演记录会保留。删除某份资料不会自动清除它在旧对话、旧推演中的内容；删除推演也不会自动删除对话文字。\n\n设置中的备份以普通 JSON 文件导出，包含基础资料、推演及其资料快照和解读、解读偏好，不包含完整聊天历史或服务认证信息。只有你主动分享或存储时，文件才交给你选择的目的地，请自行保管和删除。\n\n删除本机记录不会删除已分享的文件或 AI 服务方保存的内容。卸载应用通常移除其本机资料，但系统钥匙串中的服务认证信息可能保留。",
                    "Local records are generally retained until you delete the relevant records or app data. You can edit or delete profiles and readings in Data, and delete individual conversations or clear all history in History. Clearing all history removes chats and unfinished forms or operations while keeping profiles and saved readings. Deleting a profile does not automatically remove its contents from older conversations or reading snapshots. Deleting a reading does not automatically remove the conversation text.\n\nThe Settings backup is an ordinary JSON export containing profiles, readings with their input snapshots and interpretations, and interpretation preferences. It excludes the complete chat history and service credentials. The file is passed to a destination you select only when you choose to share or save it. Keep it secure and manage any copies yourself.\n\nDeleting local records does not delete shared files or information retained by an AI provider. Uninstalling the app normally removes local app data, but service credentials in the system Keychain may remain."
                )
            ),
            LegalSection(
                title: L10n.text("八、你的选择与信息请求", "8. Your choices and information requests"),
                text: L10n.text(
                    "你可以查看和编辑资料、删除相应记录、清除聊天历史、导出备份，以及在系统设置中管理定位权限。停止回答或撤回权限后，已完成的必要处理和已发出的请求不会自动撤销。\n\n如需查询、更正、复制、删除相关个人信息，或对处理方式提出意见，请通过下方方式联系我们。为核实请求，我们只会要求与请求相关的必要信息。应用没有注册账户，无需办理账户注销；涉及设备本机数据的请求通常需要你在设备上操作。",
                    "You can view and edit profiles, delete records, clear chat history, export a backup, and manage location permission in system settings. Stopping a reply or revoking permission does not automatically reverse completed processing or requests already sent.\n\nContact us below to request access, correction, a copy, or deletion of relevant personal information, or to raise a concern. We will request only information necessary to verify and address your request. The app has no registered account to close. Requests involving local device data usually require you to take action on that device."
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
                    Text(L10n.text("更新日期 2026年11月5日", "Updated November 5, 2026"))
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
            Link(L10n.text("AI 解读服务条款", "AI interpretation service terms"), destination: URL(string: AppLanguage.current.isEnglish
                ? "https://cdn.deepseek.com/policies/en-US/deepseek-open-platform-terms-of-service.html"
                : "https://cdn.deepseek.com/policies/zh-CN/deepseek-open-platform-terms-of-service.html")!)
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
