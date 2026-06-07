package dev.platformsre.aiop;

import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.chat.model.ChatModel;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Builds the on-board SRE agent's {@link ChatClient}.
 *
 * <p>The mochallama spring-ai adapter already contributes a bare
 * {@code ChatModel} (backed by the in-process, baked-in GGUF). Here we wrap it
 * in a {@link ChatClient} that carries the platform-sre system prompt and binds
 * the read-only {@link SreTools} as default tools, so a one-shot
 * "review &lt;cluster&gt;" call can let the model orchestrate the capabilities.
 *
 * <p>We define our own {@code ChatClient} so the adapter's
 * {@code @ConditionalOnMissingBean(ChatClient.class)} backs off — the OpenAI
 * {@code /v1/chat/completions} controller from the starter is unaffected; tools
 * for that path come from each HTTP request body.
 */
@Configuration
public class AgentConfig {

    static final String SYSTEM_PROMPT = """
            You are platform-sre, an autonomous Site Reliability operator running INSIDE a
            Talos Linux Kubernetes cluster. You review the cluster's health, reliability,
            security drift, certificates, vulnerabilities, upgrade readiness, maturity, and
            Kubernetes-worthiness — strictly READ-ONLY.

            Rules:
            - Always work against a specific cluster: dev, staging, or prod. If the user did
              not name one, ask which cluster before running any tool. Never assume prod.
            - Use the provided tools to gather evidence; do not invent findings. Each tool
              returns a JSON findings bundle from the real cluster.
            - Cite the evidence (resource kind/name, namespace, the offending field) for every
              finding you report. If a tool returns {"error": true, ...}, say so plainly and
              do not fabricate results.
            - You cannot change the cluster. If asked to fix something, explain that
              remediation is done via a GitOps pull request outside this agent, and summarise
              what the PR would change.
            - Be concise: lead with the verdict, then the top findings ranked by severity.
            """;

    @Bean
    ChatClient sreChatClient(ChatModel chatModel, SreTools sreTools) {
        return ChatClient.builder(chatModel)
                .defaultSystem(SYSTEM_PROMPT)
                .defaultTools(sreTools)
                .build();
    }
}
