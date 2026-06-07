package dev.platformsre.aiop;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.SystemMessage;
import org.springframework.ai.chat.messages.UserMessage;
import org.springframework.ai.chat.model.ChatModel;
import org.springframework.ai.chat.model.ChatResponse;
import org.springframework.ai.chat.prompt.Prompt;
import org.springframework.ai.model.tool.ToolCallingChatOptions;
import org.springframework.ai.model.tool.ToolCallingManager;
import org.springframework.ai.model.tool.ToolExecutionResult;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.ArrayList;
import java.util.List;

/**
 * One-shot convenience endpoint for the on-board SRE agent.
 *
 * <p>{@code POST /review?cluster=dev} lets the embedded model orchestrate the
 * read-only platform-sre tools and return a prose verdict. The air-tight,
 * OpenAI-compatible {@code POST /v1/chat/completions} (autoconfigured by the
 * mochallama starter) remains the primary, shared interface; this is the
 * ergonomic "review this cluster" shortcut.
 *
 * <p><b>Why a manual loop?</b> The mochallama spring-ai adapter emits tool-call
 * requests from the model but does not run the tool-execution loop itself, so a
 * plain {@code ChatClient.call()} returns the raw tool call rather than the
 * answer. We therefore drive the loop here with Spring AI's
 * {@link ToolCallingManager}: offer the tools (with internal execution disabled
 * so the model returns the call to us), execute the requested {@link SreTools}
 * method, append the result to the conversation, and call again — until the
 * model stops asking for tools or we hit the turn cap.
 */
@RestController
public class ReviewController {

    private static final Logger log = LoggerFactory.getLogger(ReviewController.class);

    /** Cap on tool-call rounds so a confused model cannot loop forever. */
    private static final int MAX_TURNS = 6;

    private final ChatModel chatModel;
    private final ToolCallingManager toolCallingManager;
    private final ToolCallback[] sreToolCallbacks;

    ReviewController(ChatModel chatModel,
                     ToolCallingManager toolCallingManager,
                     ToolCallback[] sreToolCallbacks) {
        this.chatModel = chatModel;
        this.toolCallingManager = toolCallingManager;
        this.sreToolCallbacks = sreToolCallbacks;
    }

    @PostMapping("/review")
    String review(@RequestParam(defaultValue = "dev") String cluster) {
        String user = "Review the '" + cluster + "' cluster. Call the clusterHealth tool now "
                + "with cluster=\"" + cluster + "\" to gather evidence (do not describe the "
                + "plan first — emit the tool call). After the tool returns its JSON, give me "
                + "the verdict and the top findings with evidence.";

        // internalToolExecutionEnabled(false): the model returns tool calls to US;
        // we run them via the ToolCallingManager and continue the conversation.
        //
        // temperature(0.0): CRITICAL for a small (1.5B–3B) model. The mochallama
        // spring-ai adapter does NOT inherit llamacpp.model.temperature — when the
        // options carry no temperature it falls back to the core default (0.7), at
        // which a small model drifts to *narrating* a tool call as plain JSON text
        // instead of emitting the structured tool-call the parser detects (so
        // hasToolCalls() stays false and the loop never fires). Pinning it near 0
        // makes structured tool-calling deterministic.
        ToolCallingChatOptions options = ToolCallingChatOptions.builder()
                .toolCallbacks(sreToolCallbacks)
                .internalToolExecutionEnabled(false)
                .temperature(0.0)
                .build();

        List<Message> conversation = new ArrayList<>();
        conversation.add(new SystemMessage(AgentConfig.SYSTEM_PROMPT));
        conversation.add(new UserMessage(user));

        Prompt prompt = new Prompt(conversation, options);
        ChatResponse response = chatModel.call(prompt);

        for (int turn = 0; turn < MAX_TURNS && response.hasToolCalls(); turn++) {
            log.info("review[{}] turn {}: executing {} tool call(s)",
                    cluster, turn, response.getResult().getOutput().getToolCalls().size());
            ToolExecutionResult exec = toolCallingManager.executeToolCalls(prompt, response);
            // The manager returns the full conversation history (assistant tool-call
            // message + the tool-response messages); re-prompt the model with it.
            prompt = new Prompt(exec.conversationHistory(), options);
            response = chatModel.call(prompt);
        }

        if (response.hasToolCalls()) {
            log.warn("review[{}] still requesting tools after {} turns; returning best effort",
                    cluster, MAX_TURNS);
        }
        String content = response.getResult().getOutput().getText();
        return content != null ? content : "";
    }
}
