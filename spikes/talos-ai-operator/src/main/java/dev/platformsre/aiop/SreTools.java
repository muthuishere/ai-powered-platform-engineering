package dev.platformsre.aiop;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.tool.annotation.Tool;
import org.springframework.ai.tool.annotation.ToolParam;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * The platform-sre capabilities, exposed to the embedded model as Spring AI
 * {@code @Tool} methods. One method per read-only capability; each shells out to
 * the matching Python script
 * ({@code python3 /opt/platform-sre/scripts/<x>.py --cluster <c> --json}) via
 * {@link ProcessBuilder} and returns the script's JSON verbatim.
 *
 * <p><b>Read-only by contract.</b> There is deliberately no {@code remediate}
 * tool here — remediation mutates git (a PR), which is out of scope for the
 * in-cluster agent. Every method maps to a get/list/watch-only capability.
 */
@Component
public class SreTools {

    private static final Logger log = LoggerFactory.getLogger(SreTools.class);

    /** Where the read-only Python capabilities are baked into the image. */
    private final String scriptsDir;
    /** Hard cap so a hung script can never wedge an inference request. */
    private final long timeoutSeconds;

    SreTools(
            @Value("${platformsre.scripts-dir:/opt/platform-sre/scripts}") String scriptsDir,
            @Value("${platformsre.tool-timeout-seconds:240}") long timeoutSeconds) {
        this.scriptsDir = scriptsDir;
        this.timeoutSeconds = timeoutSeconds;
    }

    @Tool(description = "Run a Talos cluster health sweep (nodes, control plane, etcd, "
            + "core workloads). Returns a JSON findings bundle. Read-only.")
    public String clusterHealth(
            @ToolParam(description = "cluster name or context: dev, staging, or prod") String cluster) {
        return run("health.py", cluster);
    }

    @Tool(description = "Run a reliability review (probes, PodDisruptionBudgets, replica "
            + "counts, resource requests/limits, anti-affinity). Returns JSON findings. Read-only.")
    public String reliability(
            @ToolParam(description = "cluster name or context: dev, staging, or prod") String cluster) {
        return run("reliability.py", cluster);
    }

    @Tool(description = "Scan for security drift (privileged pods, hostPath/hostNetwork, "
            + "missing securityContext, over-broad RBAC). Returns JSON findings. Read-only.")
    public String securityDrift(
            @ToolParam(description = "cluster name or context: dev, staging, or prod") String cluster) {
        return run("security_drift.py", cluster);
    }

    @Tool(description = "Check certificate expiry and predict cert-related outages across "
            + "the cluster and Talos PKI. Returns JSON findings. Read-only.")
    public String certs(
            @ToolParam(description = "cluster name or context: dev, staging, or prod") String cluster) {
        return run("certs.py", cluster);
    }

    @Tool(description = "Review vulnerabilities: image CVE scan, Talos/Kubernetes version "
            + "currency, and supply-chain (digest pinning). Returns JSON findings. Read-only.")
    public String vuln(
            @ToolParam(description = "cluster name or context: dev, staging, or prod") String cluster) {
        return run("vuln.py", cluster);
    }

    @Tool(description = "Run an upgrade-readiness / deprecation preflight for Kubernetes and "
            + "Talos (deprecated APIs, version skew). Returns JSON findings. Read-only.")
    public String upgrade(
            @ToolParam(description = "cluster name or context: dev, staging, or prod") String cluster) {
        return run("upgrade.py", cluster);
    }

    @Tool(description = "Produce the scored platform maturity report (aggregates the other "
            + "capabilities into dimension scores). Returns JSON. Read-only.")
    public String report(
            @ToolParam(description = "cluster name or context: dev, staging, or prod") String cluster) {
        return run("report.py", cluster);
    }

    @Tool(description = "Kubernetes-worthiness advisory: whether the workloads on this cluster "
            + "actually justify Kubernetes, scored. Returns JSON. Read-only.")
    public String worthiness(
            @ToolParam(description = "cluster name or context: dev, staging, or prod") String cluster) {
        return run("worthiness.py", cluster);
    }

    // ------------------------------------------------------------------
    // Process exec — the single choke point. Every tool returns JSON the
    // model can read, even on failure (so the model can report the error
    // rather than the request 500ing).
    // ------------------------------------------------------------------

    private String run(String script, String cluster) {
        String safeCluster = sanitizeCluster(cluster);
        List<String> cmd = List.of(
                "python3", scriptsDir + "/" + script, "--cluster", safeCluster, "--json");
        log.info("sre-tool exec: {}", String.join(" ", cmd));
        try {
            ProcessBuilder pb = new ProcessBuilder(cmd);
            pb.redirectErrorStream(false);
            Process p = pb.start();

            String stdout = readAll(p.getInputStream());
            String stderr = readAll(p.getErrorStream());

            boolean finished = p.waitFor(timeoutSeconds, TimeUnit.SECONDS);
            if (!finished) {
                p.destroyForcibly();
                return errorJson(script, safeCluster,
                        "timed out after " + timeoutSeconds + "s");
            }
            int exit = p.exitValue();
            // The scripts exit with the finding count, so a non-zero exit is
            // normal (findings present). JSON on stdout is the source of truth.
            if (stdout != null && !stdout.isBlank()) {
                return stdout;
            }
            return errorJson(script, safeCluster,
                    "no JSON on stdout (exit=" + exit + "): "
                            + (stderr == null ? "" : stderr.strip()));
        } catch (IOException e) {
            return errorJson(script, safeCluster, "exec failed: " + e.getMessage());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return errorJson(script, safeCluster, "interrupted");
        }
    }

    /**
     * The cluster value is passed as a distinct argv element (no shell), so
     * injection is already impossible. This is a defence-in-depth allowlist so
     * the model cannot point a tool at an arbitrary context.
     */
    private String sanitizeCluster(String cluster) {
        if (cluster == null) {
            return "dev";
        }
        String c = cluster.trim();
        if (!c.matches("[A-Za-z0-9@._\\-]{1,64}")) {
            log.warn("rejecting suspicious cluster value, defaulting to dev: {}", cluster);
            return "dev";
        }
        return c;
    }

    private static String readAll(java.io.InputStream in) throws IOException {
        StringBuilder sb = new StringBuilder();
        try (BufferedReader r = new BufferedReader(
                new InputStreamReader(in, StandardCharsets.UTF_8))) {
            String line;
            List<String> lines = new ArrayList<>();
            while ((line = r.readLine()) != null) {
                lines.add(line);
            }
            sb.append(String.join("\n", lines));
        }
        return sb.toString();
    }

    private static String errorJson(String script, String cluster, String message) {
        return "{\"error\":true,\"script\":\"" + script + "\",\"cluster\":\""
                + cluster + "\",\"message\":\"" + message.replace("\"", "'") + "\"}";
    }
}
