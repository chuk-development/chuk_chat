package dev.chuk.chat

import dev.chuk.chat.assist.AssistantHostActivity

/**
 * The launcher activity. It inherits the assistant MethodChannel from
 * [AssistantHostActivity], so the in-app assistant surface and the one the
 * system assist gesture opens talk to the same native handler.
 */
class MainActivity : AssistantHostActivity()
