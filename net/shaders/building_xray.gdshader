shader_type canvas_item;

// 楼体着色：透视窗 + 夜间压暗 + 窗光。
//
// 为什么窗光要画在这里（而不是独立 CanvasLayer）：
//   窗光以前挂在 layer 2 的独立画布上，永远画在整幅画面最上层、不参与 y-sort，
//   于是「被前面楼挡住的楼，夜里它的窗户还是会显示在前面那栋楼上」。
//   现在窗光跟着楼体精灵一起画，遮挡关系由 y-sort 自动保证；
//   代价是它会被全屏夜幕层压暗，所以反过来：**楼体的夜幕改由这个 shader 自己上**
//   （公式与全屏夜幕完全一致），全屏夜幕层在楼体像素上关掉，
//   窗光就既保持原亮度、又跟着楼一起被挡。
//
// 透视窗：玩家走到楼后面时只在身边挖一个柔和椭圆洞，楼体其余部分保持实心
// （旧做法是整栋楼 modulate.a=0.45，夜里楼后一旦被路灯照亮就整片透出来）。
uniform vec2 tex_size = vec2(256.0, 256.0);
uniform vec2 hole_center = vec2(0.0);      // 玩家所在位置（贴图局部像素坐标）
uniform vec2 hole_radius = vec2(17.0, 24.0);
uniform float hole_alpha = 0.20;           // 窗内不透明度（越小越透）
uniform float strength = 0.0;              // 0=实心，1=完全挖开（平滑过渡用）

uniform sampler2D glow_tex : filter_linear;                 // 烘焙好的窗光（rgb=色温, a=亮度）
uniform float glow_strength = 0.0;                          // 0=白天, 1=深夜
uniform vec4 night_color : source_color = vec4(0.03, 0.05, 0.12, 1.0);
uniform float night_alpha = 0.0;                            // 与全屏夜幕同值

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	vec3 col = c.rgb * COLOR.rgb;
	// 1) 夜幕压暗楼体（与 night_dark.gdshader 的叠加公式一致，只是提前画在楼体上）
	col = mix(col, night_color.rgb, night_alpha);
	// 2) 窗光：加色叠在夜幕之上，不受压暗影响
	vec4 gl = texture(glow_tex, UV);
	col += gl.rgb * gl.a * glow_strength;

	// 3) 透视窗
	vec2 p = UV * tex_size;
	float r = length((p - hole_center) / hole_radius);
	float t = smoothstep(0.65, 1.35, r);        // 洞内 0 → 洞外 1，边缘羽化
	float a = mix(hole_alpha, 1.0, t);
	a = mix(1.0, a, strength);
	COLOR = vec4(col, c.a * a * COLOR.a);
}
