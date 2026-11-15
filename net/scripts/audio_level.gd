class_name AudioLevel
extends RefCounted
## 全局响度校准（静态类，只放常量，不进 autoload）。
##
## 音乐 / 脚步 / 雨声三条链路各自都有 0..1 的滑杆，但素材电平完全不同：
##   music  转码 mp3，接近满刻度
##   sfx    单步 wav，峰值归一到 0.85，再按材质乘 level
##   rain   -28dBFS 的环境录音，本身按 dB 算，还额外补了 8dB
## 所以「整体调小」不能只改某一个 DEFAULT_VOLUME，得在这里给一个统一系数，
## 三个播放点各乘一次；以后想改手感只动 MASTER 一个数。
##
## ⚠️ 0.6 是**线性幅度**（≈ -4.4dB），不是听感上的 60%；听感约降四分之一，
## 比原来的常态音量舒服又不至于听不见。设回 1.0 就是原来的响度。
## 滑杆 0..1 是「相对这个上限」的刻度，存档里的值不用迁移（老存档也一起降）。
const MASTER := 0.6


## dB 形式，给按 dB 计算的链路（雨声）用
static func trim_db() -> float:
	return linear_to_db(MASTER)
