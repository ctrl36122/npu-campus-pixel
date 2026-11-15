shader_type canvas_item;
// 雨天积水：照那个雨夜效果视频的思路做 —— 形状用烘焙好的掩码裁
// （tools/bake_puddle_mask.py，噪声阈值裁出连片水洼），水面用屏幕纹理
// 加噪波扰动采样：底下是什么就映什么（沥青、石板、树影都自然带进来），
// 扰动让「倒影」一直轻轻晃。掩码边缘一圈亮边，模拟水洼边缘反光的薄水层。
//
// 挂在 WaterFX 下的 Sprite2D（puddle_mask.png 放大 8 倍盖住整张地面），
// 画在 Ground 之上、建筑之下 —— 积水在地上，人从楼前面走过要盖住它。
// strength 由 WaterFX 按雨强驱动：0（无雨）→ 1（大雨），过渡是渐湿渐干。

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest, repeat_disable;
uniform float strength : hint_range(0.0, 1.0) = 0.0;

// 两级正弦叠出的水面晃动，幅度压在 0.0015 屏幕坐标以内 —— 再大就成哈哈镜了
vec2 ripple_uv(vec2 suv) {
	float t = TIME * 1.15;
	vec2 d = vec2(
		sin(suv.y * 190.0 + t * 1.9) + 0.6 * sin(suv.y * 83.0 - t * 1.1),
		cos(suv.x * 160.0 + t * 1.6) + 0.6 * cos(suv.x * 71.0 + t * 0.9));
	return suv + d * 0.0011;
}

void fragment() {
	float m = texture(TEXTURE, UV).r;
	vec3 out_col = vec3(0.0);
	float out_a = 0.0;
	if (m >= 0.5) {
		// 边缘检测：自己在水里、四邻有岸 → 薄水亮边
		vec2 px = TEXTURE_PIXEL_SIZE;
		float l = texture(TEXTURE, UV + vec2(-px.x, 0.0)).r;
		float r = texture(TEXTURE, UV + vec2(px.x, 0.0)).r;
		float u = texture(TEXTURE, UV + vec2(0.0, -px.y)).r;
		float d = texture(TEXTURE, UV + vec2(0.0, px.y)).r;
		float edge = 1.0 - step(3.5, l + r + u + d);

		// 水面：屏幕纹理扰动采样 + 压暗偏蓝（湿沥青），天空的亮色自然透进来
		vec3 base = texture(screen_tex, ripple_uv(SCREEN_UV)).rgb;
		vec3 wet = base * vec3(0.70, 0.76, 0.88) + vec3(0.030, 0.052, 0.098);
		// 缓慢扫过的微光带，水面映天的那点碎亮
		float band = sin(UV.x * 210.0 + TIME * 0.9) * sin(UV.y * 170.0 - TIME * 0.7);
		wet += vec3(0.5, 0.62, 0.8) * smoothstep(0.72, 0.98, band) * 0.085;
		// 边缘一圈更亮的薄水
		wet = mix(wet, vec3(0.86, 0.91, 1.0), edge * 0.42);

		out_col = wet;
		out_a = clamp(0.88 * strength + edge * 0.10 * strength, 0.0, 1.0);
	}
	COLOR = vec4(out_col, out_a);
}
