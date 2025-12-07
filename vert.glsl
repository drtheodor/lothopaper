// GLSL ES 1.0
precision highp float;

// Input vertices in NDC
attribute vec2 a_Position;
attribute vec2 a_TexCoord;

// Output to fragment shader
varying vec2 v_TexCoord;

void main() {
    // Pass texture coordinates directly
    v_TexCoord = a_TexCoord;

    // Set the final position directly, no matrix math needed
    gl_Position = vec4(a_Position, 0.0, 1.0);
}
