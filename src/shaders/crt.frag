#version 330 core
in vec2 TexCoord;
out vec4 FragColor;

uniform sampler2D gbTexture;
uniform vec2 u_resolution;
uniform vec2 u_texture_size;

// Color correction matrix approximating Gambatte's "Accurate" mode
// with "Central" frontlight position.
// Simulates the DMG LCD's actual color response: slightly desaturates
// and shifts hues to match the real reflective LCD appearance.
const mat3 colorCorrection = mat3(
    0.82,  0.02,  0.08,   // column 0: R contribution to R,G,B out
    0.125, 0.855, 0.235,  // column 1: G contribution to R,G,B out
    0.055, 0.125, 0.685   // column 2: B contribution to R,G,B out
);

void main() {
    vec3 color = texture(gbTexture, TexCoord).rgb;

    // --- Color Correction ---
    color = colorCorrection * color;
    color = clamp(color, 0.0, 1.0);

    // --- LCD Pixel Grid ---
    // Simulate the visible pixel structure of the DMG LCD
    vec2 pixelPos = fract(TexCoord * u_texture_size);
    float edge = 0.06;
    float px = smoothstep(0.0, edge, pixelPos.x) * smoothstep(1.0, 1.0 - edge, pixelPos.x);
    float py = smoothstep(0.0, edge, pixelPos.y) * smoothstep(1.0, 1.0 - edge, pixelPos.y);
    float grid = mix(0.82, 1.0, px * py);
    color *= grid;

    // --- Subtle Vignette ---
    vec2 vigUV = TexCoord - 0.5;
    float vignette = 1.0 - dot(vigUV, vigUV) * 0.25;
    color *= clamp(vignette, 0.0, 1.0);

    FragColor = vec4(color, 1.0);
}
