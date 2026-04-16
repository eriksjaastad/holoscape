// CRT scanlines — horizontal lines with a slow shimmer.
// First user-visible shader effect in Holoscape.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 color = texture(iChannel0, uv);

    // Scanline: darken alternating pixel rows
    float lineCount = iResolution.y * 0.5;
    float scanline = sin(fragCoord.y * 3.14159 * lineCount / iResolution.y) * 0.5 + 0.5;
    scanline = mix(0.82, 1.0, scanline);

    // Slow shimmer: subtle brightness wave
    float shimmer = sin(uv.y * 40.0 + iTime * 0.5) * 0.015 + 1.0;

    color.rgb *= scanline * shimmer;
    fragColor = color;
}
