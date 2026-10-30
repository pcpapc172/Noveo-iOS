# Noveo iOS port

First stage: a Foundation-only Noveo transport module, with Bazel integration and an isolated Swift package for protocol checks. It implements Noveo's first-frame WebSocket password login/resume, session parsing, account-generation isolation, authentication timeout, incoming frame stream and topic-aware message envelopes. Document IDs preserve full 64-bit precision; plans use 50/100/500 MiB limits. No credentials are logged or persisted in preferences.

This module is not wired into Telegram's account/login UI yet. Existing Telegram UI, account storage, Postbox histories, media, calls and APNs are still Telegram-backed. Do not distribute this fork as a working Noveo app yet.

Next: Keychain-backed per-account credentials, username/password login UI, Noveo UUID/native peer and message ID mapping, and Postbox/TelegramEngine ingestion of users/dialogs/history/live messages. Then adapt upload/download, forum routing, notifications/APNs, membership/stars/gifts and account sync. Retain native Telegram cache and topic isolation rather than emulating all chats as one history.

The repository pins Xcode 27.1 / macOS 27 in versions.json. This Linux workspace cannot compile/run the complete UIKit app or record simulator frame verification required by AGENTS.md. The separate Noveo transport workflow compiles/tests only the Foundation module on a macOS host; it does not prove an app build. Existing app build cache/configuration is retained. Its legacy macos-13 workflow needs updating for a compatible Mac/Xcode and signing setup before a full app build. Transport-only pushes skip that known-incompatible workflow.
