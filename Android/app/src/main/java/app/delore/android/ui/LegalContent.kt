package app.delore.android.ui

const val SUPPORT_EMAIL = "contact@kandalintsev.com"
const val SUPPORT_MAILTO = "mailto:$SUPPORT_EMAIL"

data class FaqEntry(val question: String, val answer: String)

data class LegalSection(val title: String, val body: String)

object LegalCopy {
    const val TERMS_VERSION = 1
    const val NOT_RESPONSIBLE =
        "You use Retract at your own risk. We are not responsible for anything that happens — including Instagram bans, locks, lost messages, or failed unsends."
    val faq = listOf(
        FaqEntry(
            "If Instagram bans me, is that on you?",
            "No. You use Retract at your own risk. We are not responsible for anything — bans, locks, checkpoints, lost messages, failed unsends, or anything Instagram does. That is between you and Instagram.",
        ),
        FaqEntry(
            "How does Retract unsend messages?",
            "You sign in on Instagram’s own page. Retract finds DMs you sent and unsends them from this phone, the same way you would tap Unsend in a browser. We never see your password.",
        ),
        FaqEntry(
            "Do you store what I said?",
            "No. We keep chat names and the date and type of messages you sent so counts and cleanup can resume. Message text never leaves this phone and is never saved.",
        ),
        FaqEntry(
            "Why don’t photo and text counts match what I remember?",
            "Instagram labels DMs many ways: photos, disappearing photos, reels, shares, links, voice, stickers. Retract groups them into Texts, Photos & videos, Links & shared posts, Voice, and Everything else. A shared post counts as a link, not a photo. Stickers, polls, and system events land in Everything else. Refresh chats after you send new messages.",
        ),
        FaqEntry(
            "Why are some chats skipped?",
            "If we can’t tell which messages are yours, we leave that chat alone. Message requests aren’t included — only your main inbox.",
        ),
        FaqEntry(
            "What’s free and what’s Pro?",
            "The first 100 unsends are free. Pro is unlimited unsends, plus filters by date and by texts, photos, links, or voice. Subscriptions are billed by Google Play.",
        ),
        FaqEntry(
            "A message still shows in the chat",
            "Instagram can take a moment to refresh. Reopen the chat. Retract only marks a message unsent when Instagram confirms it. Some items (expired photos, a few shares) Instagram simply won’t unsend.",
        ),
        FaqEntry(
            "Is Retract part of Instagram?",
            "No. Retract isn’t affiliated with, endorsed by, or connected to Instagram or Meta. Instagram’s own rules still apply to your account.",
        ),
    )

    val terms = listOf(
        LegalSection(
            "Agreement",
            "These Terms of Use govern Retract. Retract is operated by the publisher reachable at $SUPPORT_EMAIL (“we”). By connecting Instagram or tapping I agree, you confirm you have read these Terms and you accept them. If you don’t agree, don’t use the app.",
        ),
        LegalSection(
            "At your own risk",
            "You use Retract entirely at your own risk. We are not responsible for anything that happens because you used it — including Instagram bans, locks, checkpoints, rate limits, lost or remaining messages, failed unsends, account damage, device issues, or money you spent. If Instagram is unhappy with you or with this app, that is between you and Instagram. Do not connect an account unless you accept that.",
        ),
        LegalSection(
            "What Retract does",
            "Retract shows Instagram’s own sign-in page on this device, reads which DMs you sent, and asks Instagram to unsend them the same way you could in a browser. We do not collect your password, host your messages, or run Instagram on a server of ours.",
        ),
        LegalSection(
            "Not our platform",
            "Retract is not affiliated with, endorsed by, or connected to Instagram or Meta. We do not own, operate, or control Instagram. Instagram’s terms, community standards, and enforcement are theirs. If Instagram is unhappy with you, with Unsend, or with any tool you used — including Retract — that is between you and Instagram. It is not our problem, and we are not responsible for their decisions.",
        ),
        LegalSection(
            "Your account, your consequences",
            "You are solely responsible for the Instagram account you connect and for every action taken with it through Retract. That includes unsends, rate limits, checkpoints, locks, bans, lost messages, and anything Instagram does to the account. Don’t use Retract on an account that isn’t yours. Don’t use it to break the law or Instagram’s rules. Once Instagram accepts an unsend, it cannot be undone.",
        ),
        LegalSection(
            "No responsibility",
            "To the maximum extent permitted by law, we are not responsible for anything that happens because you used Retract. That includes Instagram enforcement, account bans or restrictions, lost or remaining messages, failed unsends, data loss, device issues, missed cleanup, downtime, or any other loss, damage, claim, or cost — whether Instagram caused it, you caused it, or nobody did. We don’t owe you a fix, a refund beyond what the store requires, or compensation.",
        ),
        LegalSection(
            "No warranties",
            "Retract is provided as-is and as-available, with no warranties of any kind, express or implied. Instagram can change or block Unsend at any time. We don’t promise that every message can be unsent, that counts are perfect, that cleanup will finish, or that your account will stay in good standing.",
        ),
        LegalSection(
            "Limitation of liability",
            "If a court ever finds us liable despite these Terms, that liability is limited to the amount you paid us for Retract in the 12 months before the claim, or zero if you paid nothing. We are not liable for indirect, incidental, special, consequential, or punitive damages, or for lost profits, data, or goodwill.",
        ),
        LegalSection(
            "Subscriptions and the free allowance",
            "You can unsend 100 messages for free. After that, Pro is sold as a monthly or yearly auto-renewing subscription through Google Play. Prices shown in the app are charged by Google. Cancel in Google Play. Refunds follow Google Play’s policies and applicable law. Purchases stay with your Google account if you delete Retract’s local data.",
        ),
        LegalSection(
            "Privacy",
            "Your Instagram session, chat names, and message dates/types stay on this device. We don’t run analytics or ads. Cleanup traffic goes to Instagram from your phone. See in-app Privacy for the full explanation.",
        ),
        LegalSection(
            "Contact",
            "Questions about these Terms: $SUPPORT_EMAIL. Contacting us does not create any duty to act, defend, or compensate you.",
        ),
    )
}
