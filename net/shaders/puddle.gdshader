shader_type canvas_item;
// 雨天积水：照那个雨夜效果视频的做法 ——
//   1) 造波纹理 + step 裁出积水形状（形状在运行时算，烘焙期只给「硬面」容器）
//   2) 向内切一层 → 外圈是薄水亮边，内圈是深水
//   3) 边缘叠一层移动采样的噪声、倒着走 —— 薄水边会微微流动（倒播）
//   4) 反射透明度按造波值走：越深的水越实，边缘半透
// 水面本体用屏幕纹理加扰动采样：底下是什么就映什么（湿沥青压暗偏蓝），
// 扰动让「倒影」一直轻轻晃。
//
// 挂在 WaterFX 下的 Sprite2D（puddle_mask.png 放大 8 倍盖住整张地面），
// 画在 Ground 之上、建筑之下 —— 积水在地上，人从楼前面走过要盖住它。
// strength 由 WaterFX 按雨强驱动：0（无雨）→ 1（大雨），过渡是渐湿渐干。

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest, repeat_disable;
uniform sampler2D wave_tex : filter_linear, repeat_disable;   // 造波纹理（wave_noise.png）
uniform float strength : hint_range(0.0, 1.0) = 0.0;

const float TH = 0.60;          // step 阈值（0.60 ≈ 硬面的 29% 成水洼）
const float INSET = 0.055;      // 向内切一层的深度（薄水边的宽度）

// 两级正弦叠出的水面晃动，幅度压在 0.0011 屏幕坐标以内 —— 再大就成哈哈镜了
vec2 ripple_uv(vec2 suv) {
	float t = TIME * 1.15;
	vec2 d = vec2(
		sin(suv.y * 190.0 + t * 1.9) + 0.6 * sin(suv.y * 83.0 - t * 1.1),
		cos(suv.x * 160.0 + t * 1.6) + 0.6 * cos(suv.x * 71.0 + t * 0.9));
	return suv + d * 0.0011;
}

void fragment() {
	float m = texture(TEXTURE, UV).r;                 // 硬面容器（1px=1格）
	float wave = texture(wave_tex, UV).r;             // 造波值 0..1

	float shape = smoothstep(TH, TH + 0.015, wave) * step(0.5, m);
	float inner = smoothstep(TH + INSET, TH + INSET + 0.015, wave) * step(0.5, m);
	float rim = clamp(shape - inner, 0.0, 1.0);

	vec3 out_col = vec3(0.0);
	float out_a = 0.0;
	if (shape > 0.003) {
		// 水面：屏幕纹理扰动采样 + 压暗偏蓝（湿沥青），天空的亮色自然透进来
		vec3 base = texture(screen_tex, ripple_uv(SCREEN_UV)).rgb;
		vec3 wet = base * vec3(0.70, 0.76, 0.88) + vec3(0.030, 0.052, 0.098);
		// 缓慢扫过的微光带，水面映天的那点碎亮
		float band = sin(UV.x * 210.0 + TIME * 0.9) * sin(UV.y * 170.0 - TIME * 0.7);
		wet += vec3(0.5, 0.62, 0.8) * smoothstep(0.72, 0.98, band) * 0.085;

		// 薄水边：叠一层移动采样的噪声，倒着走（视频里的「倒播」），
		// 边缘亮线会缓缓流动、明暗起伏，像水在洼沿上荡
		float shim = texture(wave_tex, UV + vec2(-TIME * 0.012, TIME * 0.007)).r;
		float edge = rim * (0.62 + 0.38 * shim);
		wet = mix(wet, vec3(0.86, 0.91, 1.0), clamp(edge * 0.55, 0.0, 0.6));

		out_col = wet;
		// 反射透明度按造波值走：深水实、边缘透
		out_a = strength * shape * mix(0.55, 0.92, wave);
	}
	COLOR = vec4(out_col, out_a);
}
