package dev.platformsre.aiop;

import org.springframework.ai.chat.client.ChatClient;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * A one-shot convenience endpoint for the on-board SRE agent.
 *
 * <p>{@code POST /review?cluster=dev} lets the embedded model orchestrate the
 * read-only platform-sre tools and return a prose verdict. The air-tight,
 * OpenAI-compatible {@code POST /v1/chat/completions} (autoconfigured by the
 * mochallama starter) remains the primary, shared interface; this is just an
 * ergonomic shortcut for "review this cluster".
 */
@RestController
public class ReviewController {

    private final ChatClient sreChatClient;

    ReviewController(ChatClient sreChatClient) {
        this.sreChatClient = sreChatClient;
    }

    @PostMapping("/review")
    String review(@RequestParam(defaultValue = "dev") String cluster) {
        String user = "Review the '" + cluster + "' cluster. Run the relevant read-only "
                + "checks, then give me the verdict and the top findings with evidence.";
        return sreChatClient.prompt().user(user).call().content();
    }
}
