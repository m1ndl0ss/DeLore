import Foundation

enum LegalCopy {
    static let supportEmail = "contact@kandalintsev.com"
    static let termsVersion = 3
    static var supportMailto: URL { URL(string: "mailto:\(supportEmail)")! }
    static let notResponsible =
        "You use Retract at your own risk. We are not responsible for anything that happens — including Instagram bans, locks, lost messages, or failed unsends."
    static let notAffiliated =
        "Retract isn’t affiliated with, endorsed by, or connected to Instagram or Meta."
    /// Guideline 3.1.2: auto-renew terms must be visible on the purchase screen, not only in Terms.
    static let subscriptionFinePrint =
        "Payment is charged to your Apple ID at confirmation. Subscriptions auto-renew unless you turn off auto-renew at least 24 hours before the period ends. Manage in Settings → Apple ID → Subscriptions. Retract isn’t affiliated with Instagram or Meta."

    static let faq: [(question: String, answer: String)] = [
        (
            "If Instagram bans me, is that on you?",
            "No. You use Retract at your own risk. We are not responsible for anything — bans, locks, checkpoints, lost messages, failed unsends, or anything Instagram does. That is between you and Instagram."
        ),
        (
            "How does Retract unsend messages?",
            "You sign in on Instagram’s own page. Retract finds DMs you sent and unsends them from this phone, the same way you would tap Unsend in a browser. We never see your password."
        ),
        (
            "Do you store what I said?",
            "No. We never read your chats. We keep chat names and the date and type of messages you sent so counts and cleanup can resume. Message text never leaves this phone and is never saved. Connecting Instagram or buying Pro only emails the publisher your username (and promo code if used)."
        ),
        (
            "Why don’t photo and text counts match what I remember?",
            "Instagram labels DMs many ways: photos, disappearing photos, reels, shares, links, voice, stickers. Retract groups them into Texts, Photos & videos, Links & shared posts, Voice, and Everything else. A shared post counts as a link, not a photo. Stickers, polls, and system events land in Everything else. Refresh chats after you send new messages."
        ),
        (
            "Why are some chats skipped?",
            "If we can’t tell which messages are yours, we leave that chat alone. Message requests aren’t included — only your main inbox."
        ),
        (
            "Can’t I just delete the chat in Instagram?",
            "No. Deleting a chat only removes it from your inbox. The other people still see your messages. Unsend is what removes a message for everyone."
        ),
        (
            "What’s free and what’s Pro?",
            "The first 100 unsends are free. Pro is unlimited unsends, plus filters by date and by texts, photos, links, or voice. Subscriptions are billed by Apple."
        ),
        (
            "A message still shows in the chat",
            "Instagram can take a moment to refresh. Reopen the chat. Retract only marks a message unsent when Instagram confirms it. Some items (expired photos, a few shares) Instagram simply won’t unsend."
        ),
        (
            "Is Retract part of Instagram?",
            "No. Retract isn’t affiliated with, endorsed by, or connected to Instagram or Meta. Instagram’s own rules still apply to your account."
        )
    ]

    static let terms: [(title: String, body: String)] = [
        (
            "Agreement",
            "These Terms of Use govern Retract. Retract is operated by the publisher reachable at \(supportEmail) (“we”). By connecting Instagram or tapping I agree, you confirm you have read these Terms and you accept them. If you don’t agree, don’t use the app."
        ),
        (
            "At your own risk",
            "You use Retract entirely at your own risk. We are not responsible for anything that happens because you used it — including Instagram bans, locks, checkpoints, rate limits, lost or remaining messages, failed unsends, account damage, device issues, or money you spent. If Instagram is unhappy with you or with this app, that is between you and Instagram. Do not connect an account unless you accept that."
        ),
        (
            "What Retract does",
            "Retract shows Instagram’s own sign-in page on this device, reads which DMs you sent, and asks Instagram to unsend them the same way you could in a browser. We do not collect your password, host your messages, or run Instagram on a server of ours."
        ),
        (
            "Not our platform",
            "Retract is not affiliated with, endorsed by, authorized by, or connected to Instagram or Meta. Instagram and related names are used only to describe what the app does. We do not own or control Instagram. Using unofficial tools, including Retract, may violate Instagram’s Terms of Use. Instagram may restrict, challenge, or disable accounts. That risk is yours. If Instagram is unhappy with you or with this app, that is between you and Instagram."
        ),
        (
            "Your account, your consequences",
            "You are solely responsible for the Instagram account you connect and for every action taken with it through Retract. That includes unsends, rate limits, checkpoints, locks, bans, lost messages, and anything Instagram does to the account. Don’t use Retract on an account that isn’t yours. Don’t use it to break the law or Instagram’s rules. Once Instagram accepts an unsend, it cannot be undone."
        ),
        (
            "No responsibility",
            "To the maximum extent permitted by law, we are not responsible for anything that happens because you used Retract. That includes Instagram enforcement, account bans or restrictions, lost or remaining messages, failed unsends, data loss, device issues, missed cleanup, downtime, or any other loss, damage, claim, or cost — whether Instagram caused it, you caused it, or nobody did. We don’t owe you a fix, a refund beyond what the store requires, or compensation."
        ),
        (
            "No warranties",
            "Retract is provided as-is and as-available, with no warranties of any kind, express or implied. Instagram can change or block Unsend at any time. We don’t promise that every message can be unsent, that counts are perfect, that cleanup will finish, or that your account will stay in good standing."
        ),
        (
            "Limitation of liability",
            "If a court ever finds us liable despite these Terms, that liability is limited to the amount you paid us for Retract in the 12 months before the claim, or zero if you paid nothing. We are not liable for indirect, incidental, special, consequential, or punitive damages, or for lost profits, data, or goodwill."
        ),
        (
            "Subscriptions and the free allowance",
            "You can unsend 100 messages for free. After that, Pro is sold as a monthly or yearly auto-renewing subscription through the App Store. Payment is charged to your Apple ID at confirmation of purchase. Subscriptions renew unless you turn off auto-renew at least 24 hours before the period ends. Your account may be charged for renewal within 24 hours before the end of the current period. Manage or cancel in Settings → Apple ID → Subscriptions. Deleting Retract does not cancel the subscription. Refunds follow Apple’s policies and applicable law. Purchases stay with your Apple ID if you delete Retract’s local data."
        ),
        (
            "Age",
            "You must be at least 13 to use Retract. If you are under 18, use it only with a parent or guardian’s permission."
        ),
        (
            "Apple",
            "These Terms are between you and the publisher reachable at \(supportEmail), not Apple. Apple is not responsible for Retract or its content, and has no obligation to provide support. Apple and Apple’s subsidiaries are third-party beneficiaries of these Terms to the extent App Store rules require it."
        ),
        (
            "Privacy",
            "We never read your chats. Message text never leaves this phone. When you connect Instagram or buy Pro, Retract emails the publisher your Instagram username (and any promo code on purchase) so we know who signed up. No chat contents, no password, no analytics SDK. See in-app Privacy for the full explanation."
        ),
        (
            "Changes",
            "We may update these Terms. Continued use after an update means you accept the revised Terms."
        ),
        (
            "Contact",
            "Questions about these Terms: \(supportEmail). Contacting us does not create any duty to act, defend, or compensate you."
        )
    ]
}
