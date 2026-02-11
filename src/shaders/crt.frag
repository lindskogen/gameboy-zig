#version 330 core
in vec2 TexCoord;
out vec4 FragColor;

uniform sampler2D gbTexture;
uniform vec2 u_resolution;
uniform vec2 u_texture_size;

void main() {
    vec3 color = texture(gbTexture, TexCoord).rgb;

    // --- LCD Dot Matrix Grid ---
    // Prominent pixel separation matching the real DMG display
    vec2 pixelPos = fract(TexCoord * u_texture_size);

    // Horizontal gaps slightly wider than vertical (matches DMG LCD structure)
    float edgeX = 0.08;
    float edgeY = 0.12;
    float px = smoothstep(0.0, edgeX, pixelPos.x) * smoothstep(1.0, 1.0 - edgeX, pixelPos.x);
    float py = smoothstep(0.0, edgeY, pixelPos.y) * smoothstep(1.0, 1.0 - edgeY, pixelPos.y);
    float grid = mix(0.62, 1.0, px * py);
    color *= grid;

    FragColor = vec4(color, 1.0);
}
