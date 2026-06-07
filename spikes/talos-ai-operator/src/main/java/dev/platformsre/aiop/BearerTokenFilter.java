package dev.platformsre.aiop;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Conditional;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

/**
 * Optional bearer-token gate, enabled only when {@code aiop.auth.token} is set
 * (wired from the {@code AIOP_AUTH_TOKEN} env var / the Helm Secret). When
 * unset, the bean is not registered and the endpoints are open within the
 * cluster — defence is then the NetworkPolicy + ClusterIP-only Service.
 *
 * <p>Actuator health/readiness probes are always allowed so the kubelet can
 * reach them without the token.
 */
@Component
@Order(1)
@Conditional(BearerTokenFilter.TokenSet.class)
public class BearerTokenFilter extends OncePerRequestFilter {

    /** Registers the filter only when a non-blank token is configured. */
    static final class TokenSet implements org.springframework.context.annotation.Condition {
        @Override
        public boolean matches(
                org.springframework.context.annotation.ConditionContext ctx,
                org.springframework.core.type.AnnotatedTypeMetadata md) {
            String t = ctx.getEnvironment().getProperty("aiop.auth.token");
            return t != null && !t.isBlank();
        }
    }

    private final byte[] expected;

    BearerTokenFilter(@Value("${aiop.auth.token}") String token) {
        this.expected = token.getBytes(StandardCharsets.UTF_8);
    }

    @Override
    protected boolean shouldNotFilter(HttpServletRequest request) {
        String path = request.getRequestURI();
        return path.startsWith("/actuator/health");
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain chain)
            throws ServletException, IOException {
        String header = request.getHeader("Authorization");
        String presented = (header != null && header.startsWith("Bearer "))
                ? header.substring("Bearer ".length())
                : "";
        byte[] presentedBytes = presented.getBytes(StandardCharsets.UTF_8);
        if (!MessageDigest.isEqual(expected, presentedBytes)) {
            response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
            response.setContentType("application/json");
            response.getWriter().write("{\"error\":\"unauthorized\"}");
            return;
        }
        chain.doFilter(request, response);
    }
}
