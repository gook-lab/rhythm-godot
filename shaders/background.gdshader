shader_type canvas_item;

// 비트 동기 배경. 커뮤니티 관용구(godotshaders 의 pulse 계열 + Beatnik 류
// 리듬게임 배경)를 우리 식으로 조합했다 — 노이즈 텍스처 없이 사인 겹침만
// 쓰는 이유: 에셋 0개 원칙(README '곡을 왜 만들어 쓰나'와 같은 철학)이고,
// 이 정도 저주파 배경은 사인 3겹이면 충분하다.
//
// 파라미터는 전부 Main 이 프레임마다 주입한다(AudioClock 비트 위상 등).
// 배경이 스스로 시간을 세지 않는 이유: 일시정지·리플레이·시크에서
// 음악과 어긋난 채 혼자 고동치면 오히려 박자를 방해한다.
uniform float beat_phase : hint_range(0.0, 1.0) = 0.0;   // 0 = 정박
uniform float energy : hint_range(0.0, 1.0) = 0.0;        // 콤보·진행 기반
uniform float flash : hint_range(0.0, 1.0) = 0.0;         // Perfect 순간 감쇠
uniform vec3 tint : source_color = vec3(0.35, 0.55, 0.85); // 곡 난이도 색

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float t = TIME * 0.045;

	// 느리게 흐르는 띠 3겹 — 서로 소인 주파수라 반복이 눈에 안 잡힌다.
	float w = sin(p.x * 2.3 + t * 2.0 + sin(p.y * 1.7 + t * 2.6) * 1.3)
		+ sin(p.y * 3.1 - t * 1.4 + sin(p.x * 2.9 - t * 1.9) * 1.1)
		+ sin((p.x + p.y) * 1.9 + t * 3.1);
	w = w / 6.0 + 0.5;

	// 정박에서 밝았다가 지수 감쇠 — 콤보가 붙을수록 고동이 깊어진다.
	// 첫 튜닝(0.05+0.16E, 플래시 0.10)은 "너무 번쩍거린다" 피드백 —
	// 고동은 배경의 숨이지 조명이 아니다. 절반 이하로 눌렀다.
	float pulse = exp(-5.0 * beat_phase) * (0.03 + 0.08 * energy);
	float radial = 1.0 - clamp(length(p) * 0.75, 0.0, 1.0);

	vec3 base = vec3(0.030, 0.036, 0.055);
	vec3 col = base
		+ tint * (w * 0.042 + pulse * radial)
		+ tint * flash * 0.045 * radial;

	// 비네트 — 가장자리를 눌러 경로·행성 대비를 지킨다.
	col *= 1.0 - 0.38 * clamp(length(p) - 0.35, 0.0, 1.0);
	COLOR = vec4(col, 1.0);
}
