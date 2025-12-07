#version 330 core
precision mediump float;

uniform float Time;
uniform vec4 Resolution;
uniform sampler2D uTexture;

out vec4 FragColor;

vec4 background(vec2 fragCoord, vec2 screenDims) {
    // Normalized coordinates [0,1]
    vec2 uv = fragCoord / screenDims;

    // Simple vertical gradient: dark at bottom, slightly lighter at top
    vec3 topColor = vec3(0.05, 0.10, 0.25); // dark bluish
    vec3 bottomColor = vec3(0.00, 0.02, 0.10); // almost black-blue

    float t = uv.y;
    vec3 col = mix(bottomColor, topColor, t);

    // optional subtle vignette
    vec2 c = uv - 0.5;
    float vignette = 1.0 - dot(c, c) * 0.8;
    vignette = clamp(vignette, 0.0, 1.0);

    col *= vignette;

    return vec4(col, 1.0);
}

void main(void) {
    vec2 screenDims = Resolution.xy;

    ivec2 textureDims_i = textureSize(uTexture, 0);
    vec2 textureDims = vec2(textureDims_i) * 2.0;

    vec2 maxPos = screenDims - textureDims;

    // If the texture is larger than the screen, just fullscreen it
    if (maxPos.x < 0.0 || maxPos.y < 0.0) {
        vec2 uv = gl_FragCoord.xy / screenDims;
        vec4 tex = texture(uTexture, uv);
        FragColor = tex;
        return;
    }

    float speedX = 0.04;
    float speedY = 0.02;

    float timeX = Time * speedX;
    float timeY = Time * speedY;

    float normalizedPosX = abs(fract(timeX) * 2.0 - 1.0);
    float normalizedPosY = abs(fract(timeY) * 2.0 - 1.0);

    vec2 ImagePosition = vec2(
            normalizedPosX * maxPos.x,
            normalizedPosY * maxPos.y
        );

    vec2 fragCoord = gl_FragCoord.xy;
    vec2 relativeCoord = fragCoord - ImagePosition;

    // Outside the image rect → gradient background
    if (relativeCoord.x < 0.0 || relativeCoord.y < 0.0 ||
            relativeCoord.x > textureDims.x || relativeCoord.y > textureDims.y) {
        FragColor = background(fragCoord, screenDims);
        return;
    }

    vec2 uv = relativeCoord / textureDims;
    uv.y = 1.0 - uv.y;

    vec4 tex = texture(uTexture, uv);
    FragColor = tex;
}
