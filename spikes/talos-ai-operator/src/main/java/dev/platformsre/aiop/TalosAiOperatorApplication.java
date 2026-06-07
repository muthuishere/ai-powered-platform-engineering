package dev.platformsre.aiop;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Talos AI Operator — the Ch9 capstone.
 *
 * <p>An on-prem, air-tight Spring Boot agent that embeds mochallama (a local
 * tool-calling LLM, in-process via Project Panama FFM, model baked into the
 * image) and exposes both:
 * <ul>
 *   <li>an OpenAI-compatible {@code POST /v1/chat/completions} endpoint
 *       (autoconfigured by the mochallama starter), and</li>
 *   <li>an on-board SRE agent that orchestrates the read-only platform-sre
 *       capabilities ({@link SreTools}) over the baked-in model.</li>
 * </ul>
 *
 * No egress, no model download, no external LLM daemon.
 */
@SpringBootApplication
public class TalosAiOperatorApplication {
    public static void main(String[] args) {
        SpringApplication.run(TalosAiOperatorApplication.class, args);
    }
}
