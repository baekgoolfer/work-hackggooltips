# mlx-whisper 레시피 (조사 요약)

> 조사 요약. 구현은 `pipeline/mcap/{asr,asr_engines,vad,audioprep}.py`이고 고정한 패키지 목록은 `pipeline/requirements.lock.txt`다.
> 검증 범위: **tiny 모델 + large-v3와 동일 구조의 랜덤 가중치 하네스**. 실제 large-v3 가중치로는 아직 안 돌렸다(다운로드 보류). 수치 중 [W]는 웹/문서 근거이며 로컬 재현 전.

## 설치
- mlx-whisper **0.4.3**(2025-08-29)이 PyPI 최신. 메타데이터는 `torch`를 요구하지만 **코드에서 import하지 않는다** → `pip install --no-deps -r pipeline/requirements.lock.txt`(29개 pin: mlx 0.32.3, numba 0.68.0, huggingface_hub 2.1.1 …). Python 3.13 venv **약 547MB**에서 설치/실행 검증. 평범한 `pip install mlx-whisper`는 torch를 끌어와 1.2GB가 된다.
- 첫 `import mlx_whisper`는 **~24초**(numba 컴파일/캐시) → `doctor`에서 pre-warm.
- ffmpeg 불필요: `transcribe()`는 float32 mono 16kHz **numpy 배열**을 받는다. 파일 경로를 주면 `FileNotFoundError: 'ffmpeg'`.

## 입력/호출 규칙
- WAV는 stdlib `wave` + numpy로 읽어 `float32/32768`. int16 배열·`language=None`·`beam_size`(미구현, NotImplementedError)·`initial_prompt=''`(→`None`)·`verbose=False` 금지. `path_or_hf_repo`는 항상 명시.
- 모델: `snapshot_download(repo, revision='49e6aa286ad60c14352c404340ded53710378a11', local_files_only=True)` 우선, 없으면 다운로드(3.08GB, `allow_patterns=['config.json','weights.*']`), 반환된 **로컬 디렉터리**를 `path_or_hf_repo`로 전달. revision 고정 이유: 0.4.3이 `model.safetensors`만 있는 재업로드를 못 읽을 수 있음.
- `language=None`은 **첫 30초에서 한 번만** 감지. `initial_prompt`는 `condition_on_previous_text=False`일 때 **`transcribe()` 호출당 첫 윈도우에만** 적용 → 청크마다 호출. mlx 0.4.3은 OpenAI 원본과 `no_speech` fallback 로직이 다르고, `hallucination_silence_threshold`는 `word_timestamps=True`에서만 동작.

## 권장 파라미터 (SPEC 13.2에 반영됨)
`condition_on_previous_text=False, temperature=(0.0,0.2,0.4,0.6), compression_ratio_threshold=2.4, logprob_threshold=-1.0, no_speech_threshold=0.6, word_timestamps=False, fp16=True, verbose=None` + 청크별 `language`/`initial_prompt`, 청크 후 `mx.clear_cache()`.

## VAD / 청킹
- 에너지 VAD만 쓰면 비음성 소리(키보드, 팬, 기침)가 Whisper로 들어감. **Silero-ONNX**(onnxruntime 21.5MB + 모델 2.3MB, torch 불필요)가 비음성 스트레스 테스트에서 오검출 0 vs 5. 논문 인용 [W]: Silero 8.0% vs 무처리 104.8% WER(비음성 많은 오디오).
- 청크: 같은 언어 인접 구간 gap ≤2.5s, 길이 ≤27.4s(패딩 0.3s 포함 28s), 긴 구간은 마지막 35% 내 가장 조용한 100ms에서 절단, 0.4s 미만 발화 건너뜀. Silero 진입 p≥0.5 / 유지 p≥0.35 / 0.30s 닫힘 / 0.25s 미만 제거.

## 언어
`region_languages()`: ≤6개 구간(≥3s)으로 트랙 prior 탐침 → 전부 p≥0.95 일치면 단일언어 빠른 경로, 아니면 ≥2.5s 구간 전체를 {ko,en}로 제한한 LID(B=4 배치). p_other≥0.90일 때만 이탈. 짧은 구간은 직전 라벨 상속. (임계값은 tiny/TTS에서만 보정 → large-v3 + 실제 음성으로 재튜닝 필요)

## 프롬프트
- 토큰 한도 223 → 예산 ≤100–120. 영어 용어를 라틴 문자로 유지시키는 효과는 [W] 근거뿐(OpenAI 가이드: 철자/스타일 유도, 효과 불확실). tiny에서 프롬프트 regurgitation(프롬프트 용어를 그대로 토해냄)이 재현됨 → echo 가드 + 프롬프트 없이 1회 재시도.
- 예시 vocabulary 30개 안팎(짧은 용어): 단순 나열 120토큰, 한국어 문장에 넣으면 87토큰.

## 후처리 필터
SPEC 13.2 참고. 유령 문구 목록은 [W] 시드(PyTorchKR 스레드, Damwha PR #45, "구독과 좋아요", "MBC ○○○", "감사합니다")이므로 운영 로그의 드롭 내역으로 확장할 것.

## 성능/메모리 (large-v3 추정, 실가중치 재측정 필요)
- 인코더 ~0.58s/30s 윈도우 + 디코드 ~20ms/token, 피크 MLX 메모리 3.9GB(`clear_cache()` 사용 시 3.1GB 상주; 미사용 시 5–6GB+). 1시간 발화당 **8–13분**, 코드스위칭 트랙은 LID로 +3–6분. 배치 디코드는 v1에서 안 함(B=4에서 1.5배 이득뿐).
- 연속 300회 `transcribe()` 호출, 스레딩 모두 문제 없었음(tiny).

## 위험
mlx-whisper 0.4.3은 14개월째 사실상 미관리(no_speech 편차, beam search 미구현, repetition_penalty/no_repeat_ngram_size 없음). 필요하면 `mlx_whisper.decoding.decode` 주위에 커스텀 루프를 짜는 길이 있으나 v1에서는 하지 않음.
