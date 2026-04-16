// Identity shader — passthrough. Terminal looks unchanged.
// Use this to verify the Metal compositor is working without
// any visible effect on the terminal output.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = texture(iChannel0, fragCoord / iResolution.xy);
}
