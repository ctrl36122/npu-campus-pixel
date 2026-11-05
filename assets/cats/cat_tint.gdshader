shader_type canvas_item;

// 同一张 Oreo Cat 原图的运行时重新着色（不改动 PNG 本身）。
// 思路：把原图的暗色毛区映射到 dark_color、亮色毛区映射到 light_color，
// 再按原像素亮度保留明暗层次；红心等强调色保持原样。
// tint_strength = 0 即完全保留原图配色（奶牛猫）。

uniform vec4 dark_color : source_color = vec4(0.239, 0.204, 0.271, 1.0);
uniform vec4 light_color : source_color = vec4(0.93, 0.92, 0.89, 1.0);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	if (c.a < 0.02) {
		COLOR = c;
	} else {
		float is_red = step(c.g * 1.45, c.r) * step(c.b * 1.45, c.r);
		float lum = dot(c.rgb, vec3(0.299, 0.587, 0.114));
		vec3 mapped = mix(dark_color.rgb, light_color.rgb, smoothstep(0.10, 0.72, lum));
		mapped *= 0.80 + 0.32 * lum;
		vec3 dyed = mix(c.rgb, mapped, tint_strength);
		COLOR = vec4(mix(dyed, c.rgb, is_red * tint_strength), c.a);
	}
}
