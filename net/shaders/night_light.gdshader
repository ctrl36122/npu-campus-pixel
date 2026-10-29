shader_type canvas_item;
render_mode blend_add;

// 路灯的暖色补光：只加在 lightmap 照亮的地方（灯脚下最暖，向外渐隐）。
// 与 night_dark 成对使用——先「把夜幕挖薄」露出路面，再给路面染一层暖黄。
uniform sampler2D lightmap : filter_linear;
uniform vec3 warm_color : source_color = vec3(1.0, 0.84, 0.58);
uniform float strength = 0.0;

uniform vec2 cam_center = vec2(0.0);
uniform vec2 screen_size = vec2(1152.0, 648.0);
uniform vec2 zoom = vec2(1.0);
uniform vec2 world_origin = vec2(0.0);
uniform vec2 world_size = vec2(6784.0, 12800.0);

void fragment() {
	vec2 sp = (SCREEN_UV - 0.5) * screen_size;
	vec2 wp = cam_center + sp / zoom;
	vec2 uv = (wp - world_origin) / world_size;
	float l = 0.0;
	if (uv.x > 0.0 && uv.x < 1.0 && uv.y > 0.0 && uv.y < 1.0) {
		// 同 night_dark：g 通道排除掉被楼盖住的格子，暖光只落在真的看得见的地面上
		vec2 lm = texture(lightmap, uv).rg;
		l = lm.r * smoothstep(0.40, 0.85, lm.g);
	}
	// 平方一下：只有真正被照亮的核心区才明显偏暖，边缘不至于发黄
	float a = l * l * strength;
	COLOR = vec4(warm_color, a);
}
