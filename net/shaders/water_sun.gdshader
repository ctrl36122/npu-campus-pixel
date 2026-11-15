shader_type canvas_item;
render_mode blend_add, unshaded;

// 晴天给水面上色（加法混合，挂在 WaterFX 下面）。
//
// 贴图是 assets/water_mask.png：一格一个像素的黑白图，Sprite2D 按 8 倍放大
// 正好盖住整张地面，所以不用做任何世界坐标换算，位置天然对齐。
//
// 用加法而不是覆盖：原水色是 4 档精确定色（判水依据不能改），
// 加法只往上加蓝和一点绿，原来的深浅层次原样保留 —— 覆盖会把 4 档压成一片。
//
// strength 由天气驱动：晴天 ~0.9，阴天 ~0.15，下雨/下雪 0。
// 阴雨天水面反而更暗更浑，加蓝会显得假，所以直接关掉。

uniform float strength = 0.0;
uniform vec3 tint = vec3(0.014, 0.092, 0.268);

void fragment() {
	float m = texture(TEXTURE, UV).r;
	COLOR = vec4(tint, m * strength);
}
