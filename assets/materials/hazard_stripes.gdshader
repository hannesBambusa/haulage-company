shader_type spatial;
// Yellow/black diagonal hazard paint for flat quads. Set quad_size to the
// mesh size in metres so stripe width stays constant.

uniform vec4 color_a : source_color = vec4(0.93, 0.72, 0.12, 1.0);
uniform vec4 color_b : source_color = vec4(0.07, 0.07, 0.07, 1.0);
uniform vec2 quad_size = vec2(4.0, 0.6);
uniform float stripe_width = 0.35;

void fragment() {
	vec2 p = UV * quad_size;
	float s = step(0.5, fract((p.x + p.y) / (2.0 * stripe_width)));
	ALBEDO = mix(color_a.rgb, color_b.rgb, s);
	ROUGHNESS = 0.85;
}
