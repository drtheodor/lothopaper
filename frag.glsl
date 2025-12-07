precision highp float;

uniform highp float Time;
uniform vec4 Resolution;

float time;
float vort_speed = 1.0;
vec4 colour_1 = vec4(0.996078431372549,0.37254901960784315,0.3333333333333333,1.0);
vec4 colour_2 = vec4(0.0,0.615686274509804,1.0,1.0);
float mid_flash = 0.0;
float vort_offset = 0.0;

#define PIXEL_SIZE_FAC 1920.0
#define BLACK 0.6*vec4(79.0/255.0,99.0/255.0, 103.0/255.0, 1.0/0.6)

vec4 easing(vec4 t, float power)
{
    return vec4(
        pow(t.r, power),
        pow(t.g, power),
        pow(t.b, power),
        pow(t.a, power)
    );
}

vec4 effect(vec2 screen_coords, float scale) {
    // Convert to UV coords (0-1) and floor for pixel effect
    vec2 uv = screen_coords;
    uv = floor(uv * (PIXEL_SIZE_FAC / 2.0)) / (PIXEL_SIZE_FAC / 2.0);
    uv /= scale;
    float uv_len = length(uv);

    // Adding in a center swirl, changes with time
    float speed = time * vort_speed;
    float new_pixel_angle = atan(uv.y, uv.x) + (2.2 + 0.4*min(6.0, speed)) * uv_len - 1.0 - speed*0.05 - min(6.0, speed) * speed * 0.02 + vort_offset;
    vec2 mid = (Resolution.xy / length(Resolution.xy)) * 0.5;
    vec2 sv = vec2((uv_len * cos(new_pixel_angle) + mid.x), (uv_len * sin(new_pixel_angle) + mid.y)) - mid;

    // Now add the smoke effect to the swirled UV
    sv *= 30.0;
    speed = time * 6.0 * vort_speed + vort_offset + 5.0;
    vec2 uv2 = vec2(sv.x + sv.y);

    for(int i = 0; i < 5; i++) {
        uv2 += sin(max(sv.x, sv.y)) + sv;
        sv += 0.5 * vec2(cos(5.1123314 + 0.353 * uv2.y + speed*0.131121),
                         sin(uv2.x - 0.113*speed));
        sv -= vec2(cos(sv.x + sv.y) - sin(sv.x*0.711 - sv.y));
    }

    // Make the smoke amount range from 0 - 2
    float smoke_res = min(2.0, max(-2.0, 1.5 + length(sv)*0.12 - 0.17*(min(10.0, time*1.2 - 0.0))));
    if (smoke_res < 0.2) {
        smoke_res = (smoke_res - 0.2) * 0.6 + 0.2;
    }

    float c1p = max(0.0, 1.0 - 2.0 * abs(1.0 - smoke_res));
    float c2p = max(0.0, 1.0 - 2.0 * smoke_res);
    float cb = 1.0 - min(1.0, c1p + c2p);

    vec4 ret_col = colour_1*c1p + colour_2*c2p + vec4(cb*BLACK.rgb, cb*colour_1.a);
    float mod_flash = max(mid_flash*0.8, max(c1p, c2p)*5.0 - 4.4) + mid_flash * max(c1p, c2p);

    return easing(ret_col*(1.0 - mod_flash) + mod_flash*vec4(1.0, 1.0, 1.0, 1.0), 1.5);
}

void main() {
    // Normalized pixel coordinates (from 0 to 1)
    vec2 uv = gl_FragCoord.xy / Resolution.xy;
    uv -= 0.5;
    uv.x *= Resolution.x / Resolution.y;

    // Time varying pixel color
    time = Time + 10.0;

    // Output to screen
    gl_FragColor = effect(uv, 2.0);
}
