shader_type canvas_item;
render_mode blend_mix, unshaded;

// 天气调色：整屏一起做，不动任何烘焙贴图。
//
// 原来白天完全没有后处理，画面就是烘焙出来的那份颜色 —— 偏灰偏冷，
// 看着像阴天。这一层按当前天气给「曝光 / 暖度 / 饱和 / 对比 / 叠色」五项，
// 晴天往上推（更亮、更暖、更饱和），阴雨往下压（更灰、更冷、更闷）。
//
// 晴天额外加一道阳光：右上角一团暖白光晕往外衰减，光斑落在楼顶和草地上，
// 越远越淡 —— 一屏之内哪儿都有点暖，又不会糊成一片黄。
// 这一层是屏幕空间的（跟镜头走），当作镜头/大气效果看，不做世界位置。
//
// 读屏靠 BackBufferCopy（Arena 里在同一个 CanvasLayer 里先放一个），
// 所以它处理的是「已经画好的整幅画面」，包括夜景层与天空层。

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_nearest;

uniform float exposure = 1.0;      // 亮度乘数
uniform float saturation = 1.0;    // 饱和度
uniform float contrast = 1.0;      // 对比（围绕 0.5 中灰）
uniform vec3 warm = vec3(0.0);     // 暖偏移，主要作用在中间调
uniform vec4 tint = vec4(1.0, 1.0, 1.0, 0.0);  // 叠色（a 为强度）
uniform float amount = 1.0;        // 总权重：夜里由 Arena 压到 0，不影响夜景

// 阳光：sun 是晴天权重，sun_pos 是屏幕上的光斑中心（UV），sun_gain 是峰值强度
uniform float sun = 0.0;
uniform vec2 sun_pos = vec2(0.40, -0.07);
uniform vec3 sun_col = vec3(1.0, 0.935, 0.780);
uniform float sun_gain = 0.10;

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;

	vec3 d = c * exposure;
	// 暖偏移只在中间调生效：阴影里加暖会糊成一片橘，高光里加暖会直接过曝
	float mid = 1.0 - abs(dot(c, vec3(0.333)) * 2.0 - 1.0);
	d += warm * mid;

	// 对比
	d = (d - 0.5) * contrast + 0.5;

	// 饱和度（在对比之后做，避免先提饱和再压对比导致发灰）
	float l = dot(d, vec3(0.299, 0.587, 0.114));
	d = mix(vec3(l), d, saturation);

	// 叠色
	d = mix(d, d * (1.0 - tint.a) + tint.rgb * tint.a, 1.0);

	// 阳光：一团高斯光斑 + 一层很淡的整体暖雾。
	// 光斑按屏幕比例椭圆化（横向拉宽），免得在高瘦屏上像个圆点。
	vec2 dv = (SCREEN_UV - sun_pos) * vec2(1.0, 0.62);
	float glow = exp(-dot(dv, dv) * 4.2);
	d += sun_col * (glow * sun_gain + 0.014) * sun;

	COLOR = vec4(clamp(mix(c, clamp(d, 0.0, 1.0), amount), 0.0, 1.0), 1.0);
}
