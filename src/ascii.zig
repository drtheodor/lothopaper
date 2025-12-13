const HEADER =
    \\==================================================================================
    \\
    \\db       .d88b.  d888888b db   db  .d88b.  d8888b.  .d8b.  d8888b. d88888b d8888b.
    \\88      .8P  Y8. `~~88~~' 88   88 .8P  Y8. 88  `8D d8' `8b 88  `8D 88'     88  `8D
    \\88      88    88    88    88ooo88 88    88 88oodD' 88ooo88 88oodD' 88ooooo 88oobY'
    \\88      88    88    88    88~~~88 88    88 88~~~   88~~~88 88~~~   88~~~~~ 88`8b
    \\88booo. `8b  d8'    88    88   88 `8b  d8' 88      88   88 88      88.     88 `88.
    \\Y88888P  `Y88P'     YP    YP   YP  `Y88P'  88      YP   YP 88      Y88888P 88   YD
    \\
;

const VERSION_PREFIX = " Version: ";
const VERSION_SUFFIX = " ";
const TAIL = "\n";

const std = @import("std");

const VERSION = @import("build.zig.zon").version;
pub const ASCII = getAscii();

fn getAscii() []const u8 {
    var iterator = std.mem.splitSequence(u8, HEADER, "\n");
    const lineLen = iterator.next().?.len;

    const fullVersion = VERSION_PREFIX ++ VERSION ++ VERSION_SUFFIX;
    const fillerLen = @divTrunc(lineLen - fullVersion.len, 2);

    const sep = "=" ** fillerLen;
    return HEADER ++ "\n" ++ sep ++ fullVersion ++ sep ++ "\n" ++ TAIL;
}

fn getAsciiLineLength() comptime_int {
    const iterator = std.mem.splitSequence(u8, HEADER, "\n");
    return iterator.next();
}

pub const DEFAULT_VERT_SHADER =
    \\#version 330 core
    \\
    \\in vec2 a_Position;
    \\in vec2 a_TexCoord;
    \\
    \\out vec2 v_TexCoord;
    \\
    \\void main() {
    \\    // Pass texture coordinates directly
    \\    v_TexCoord = a_TexCoord;
    \\
    \\    // Set the final position directly, no matrix math needed
    \\    gl_Position = vec4(a_Position, 0.0, 1.0);
    \\}
;

pub const DEFAULT_FRAG_SHADER =
    \\#version 330 core
    \\
    \\uniform float Time;
    \\uniform vec4 Resolution;
    \\uniform sampler2D uTexture;
    \\
    \\out vec4 FragColor;
    \\
    \\vec4 background(vec2 fragCoord, vec2 screenDims) {
    \\    // Normalized coordinates [0,1]
    \\    vec2 uv = fragCoord / screenDims;
    \\
    \\    // Simple vertical gradient: dark at bottom, slightly lighter at top
    \\    vec3 topColor = vec3(0.05, 0.10, 0.25); // dark bluish
    \\    vec3 bottomColor = vec3(0.00, 0.02, 0.10); // almost black-blue
    \\
    \\    float t = uv.y;
    \\    vec3 col = mix(bottomColor, topColor, t);
    \\
    \\    // optional subtle vignette
    \\    vec2 c = uv - 0.5;
    \\    float vignette = 1.0 - dot(c, c) * 0.8;
    \\    vignette = clamp(vignette, 0.0, 1.0);
    \\
    \\    col *= vignette;
    \\
    \\    return vec4(col, 1.0);
    \\}
    \\
    \\void main(void) {
    \\    vec2 screenDims = Resolution.xy;
    \\
    \\    ivec2 textureDims_i = textureSize(uTexture, 0);
    \\    vec2 textureDims = vec2(textureDims_i) * 2.0;
    \\
    \\    vec2 maxPos = screenDims - textureDims;
    \\
    \\    // If the texture is larger than the screen, just fullscreen it
    \\    if (maxPos.x < 0.0 || maxPos.y < 0.0) {
    \\        vec2 uv = gl_FragCoord.xy / screenDims;
    \\        vec4 tex = texture(uTexture, uv);
    \\        FragColor = tex;
    \\        return;
    \\    }
    \\
    \\    float speedX = 0.04;
    \\    float speedY = 0.02;
    \\
    \\    float timeX = Time * speedX;
    \\    float timeY = Time * speedY;
    \\
    \\    float normalizedPosX = abs(fract(timeX) * 2.0 - 1.0);
    \\    float normalizedPosY = abs(fract(timeY) * 2.0 - 1.0);
    \\
    \\    vec2 ImagePosition = vec2(
    \\            normalizedPosX * maxPos.x,
    \\            normalizedPosY * maxPos.y
    \\        );
    \\
    \\    vec2 fragCoord = gl_FragCoord.xy;
    \\    vec2 relativeCoord = fragCoord - ImagePosition;
    \\
    \\    // Outside the image rect → gradient background
    \\    if (relativeCoord.x < 0.0 || relativeCoord.y < 0.0 ||
    \\            relativeCoord.x > textureDims.x || relativeCoord.y > textureDims.y) {
    \\        FragColor = background(fragCoord, screenDims);
    \\        return;
    \\    }
    \\
    \\    vec2 uv = relativeCoord / textureDims;
    \\    uv.y = 1.0 - uv.y;
    \\
    \\    vec4 tex = texture(uTexture, uv);
    \\    FragColor = tex;
    \\}
;

pub const SHADERTOY_FRAG_PREFIX =
    \\#version 330 core
    \\#define iTime Time
    \\#define iMouse Mouse
    \\#define iResolution Resolution
    \\out vec4 FragColor;
    \\uniform float Time;
    \\uniform vec4 Resolution;
    \\uniform vec4 Mouse;
    \\
;

pub const SHADERTOY_FRAG_SUFFIX =
    \\
    \\void main() {
    \\    mainImage(FragColor, gl_FragCoord.xy);
    \\}
;
