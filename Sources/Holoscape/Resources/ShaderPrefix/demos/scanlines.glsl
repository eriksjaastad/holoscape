// CRT scanlines over terminal content.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 color = texture(iChannel0, uv);

    // Bold scanlines: every 3rd pixel row darkened to 40%
    float scanline = mod(fragCoord.y, 3.0) < 1.0 ? 0.4 : 1.0;

    color.rgb *= scanline;
    fragColor = color;
}
