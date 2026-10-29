shader_type canvas_item;

// Minecraft 式格子光照驱动的夜幕：
// lightmap.r = 该点的光照强度（0..1，由路灯 flood-fill 传播烘焙）。
// 有光的地方夜幕变薄 → 底下的砖路/草地露出来，就是「路灯真的点亮了附近」；
// 无光的地方照常压暗成夜色。
uniform sampler2D lightmap : filter_linear;
uniform vec4 dark_color : source_color = vec4(0.02, 0.05, 0.14, 1.0);
uniform float night_alpha = 0.0;

// 相机投影参数（每帧由 Arena 更新）：屏幕像素 → 世界坐标
uniform vec2 cam_center = vec2(0.0);
uniform vec2 screen_size = vec2(1152.0, 648.0);
uniform vec2 zoom = vec2(1.0);
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(6784.0, 12800.0);

void fragment() {
	vec2 sp = (SCREEN_UV - 0.5) * screen_size;   // 屏幕像素偏移（中心为原点）
	vec2 wp = cam_center + sp / zoom;            // 对应的世界坐标
	vec2 uv = (wp - world_origin) / world_size;  // 光照图 UV
	float l = 0.0;
	float gnd = 0.0;
	if (uv.x > 0.0 && uv.x < 1.0 && uv.y > 0.0 && uv.y < 1.0) {
		// r = 光照强度；g = 这块屏幕像素是不是「看得见的地面」（0 = 楼的墙面/屋顶，
		// 或者是被楼挡住的地面）。只有看得见的地面才被路灯点亮，
		// 否则楼后的光会整片糊到楼身上。
		vec2 lm = texture(lightmap, uv).rg;
		gnd = smoothstep(0.40, 0.85, lm.g);
		l = lm.r * gnd;
	}
	// 楼体像素在这里不压暗：楼体由自己的 shader 压暗（building_xray.gdshader），
	// 这样它的窗光能叠在夜幕之上（既保持亮度，又跟着楼一起被前面的楼挡住）。
	float a = night_alpha * (1.0 - l) * gnd;
	COLOR = vec4(dark_color.rgb, a);
}
