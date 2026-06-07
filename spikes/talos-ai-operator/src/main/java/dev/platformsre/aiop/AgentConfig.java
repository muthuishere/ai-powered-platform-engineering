package dev.platformsre.aiop;

import org.springframework.ai.model.tool.ToolCallingManager;
import org.springframework.ai.support.ToolCallbacks;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Wires the on-board SRE agent's tool-calling machinery.
 *
 * <p>The mochallama spring-ai adapter contributes a bare {@link
 * org.springframework.ai.chat.model.ChatModel} (backed by the in-process,
 * baked-in GGUF). That adapter emits tool-call <em>requests</em> from the model
 * but does NOT run the tool-execution loop itself — so a plain
 * {@code ChatClient.call()} returns the raw tool call instead of the answer.
 *
 * <p>We therefore drive the loop explicitly in {@link ReviewController} using
 * Spring AI's {@link ToolCallingManager}: call the model, and while the response
 * carries tool calls, execute the matching {@link SreTools} {@code @Tool} method,
 * append the result to the conversation, and call again. These beans expose the
 * pieces that controller needs.
 */
@Configuration
public class AgentConfig {

    static final String SYSTEM_PROMPT = """
            You are platform-sre, an autonomous Site Reliability operator running INSIDE a
            Talos Linux Kubernetes cluster. You review the cluster's health, reliability,
            security drift, certificates, vulnerabilities, upgrade readiness, maturity, and
            Kubernetes-worthiness — strictly READ-ONLY.

            Rules:
            - Always work against a specific cluster. The user's message names the cluster to
              review; treat that name as the cluster argument verbatim (it may be dev, staging,
              prod, or any cluster context name such as cherry-bench). Only if NO cluster name
              appears anywhere in the request should you ask which cluster. Never assume prod.
            - You MUST call a tool to gather evidence before writing any verdict. Do not
              describe what you will do or promise to run checks — emit the tool call
              immediately on your first turn, passing the named cluster as the argument. Never
              invent findings; each tool returns a JSON findings bundle from the real cluster.
            - Cite the evidence (resource kind/name, namespace, the offending field) for every
              finding you report. If a tool returns {"error": true, ...}, say so plainly and
              do not fabricate results.
            - You cannot change the cluster. If asked to fix something, explain that
              remediation is done via a GitOps pull request outside this agent, and summarise
              what the PR would change.
            - Be concise: lead with the verdict, then the top findings ranked by severity.
            """;

    /**
     * The read-only platform-sre capabilities, adapted to Spring AI
     * {@link ToolCallback}s the model can be offered and the manager can execute.
     */
    @Bean
    ToolCallback[] sreToolCallbacks(SreTools sreTools) {
        return ToolCallbacks.from(sreTools);
    }

    /**
     * Default tool-calling manager (resolver + exception processor defaults). We
     * call {@link ToolCallingManager#executeToolCalls} ourselves so we control
     * the loop rather than relying on a model-side integration the mochallama
     * adapter does not provide.
     */
    @Bean
    ToolCallingManager toolCallingManager() {
        return ToolCallingManager.builder().build();
    }
}
