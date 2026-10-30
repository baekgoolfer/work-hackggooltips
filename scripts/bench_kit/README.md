# ASR 벤치마크 키트 (요약)

다른 Apple Silicon Mac에서 `scripts/bench_asr.py`만 돌리기 위한 **선택 기능**이다 (Intel Mac은 MLX가 안 돼서 쓰지 않는다). 전체 설명, 다운로드 크기, 결과 읽는 법, 프라이버시, 문제 해결은 **`docs/BENCH_KIT.md`**.
**이 폴더의 스크립트는 `make bench-kit`으로 만든 키트(루트에 `BENCH_KIT` 마커 파일)를 풀어 놓은 곳에서만 실행된다.** 전체 저장소에서는 거부한다.

키트에는 녹음, 정답 전사본, 결과가 들어 있지 않다. 사용자 본인의 녹음으로 직접 비교하는 도구다 (English: the kit holds no recording and no result; you bring your own audio).

**오디오는 이 Mac과 메인 Mac 사이에서만 오간다. Drive, iCloud, Slack, 이메일에 올리지 않는다.** 설치는 이 폴더 안에서만 일어나며(`support/bench-venv`, `hf/`, `bench.env`) 폴더를 지우면 모두 사라진다. 운영 venv는 없고 벤치 venv 하나뿐이다.

## 메인 Mac에서

```bash
make bench-kit                                   # build/bench-kit.tar.gz
# 10~20분짜리 실제 회의 오디오(m4a/wav)를 고른다. 옮기는 방법은 AirDrop / scp / USB.
scp build/bench-kit.tar.gz 회의오디오.m4a alice@other-mac.local:~/
```

## 다른 Mac에서

```bash
mkdir -p ~/mcap-bench && tar -xzf ~/bench-kit.tar.gz -C ~/mcap-bench && cd ~/mcap-bench

# 1) 계획과 정확한 다운로드 크기 확인 (아무것도 바꾸지 않음)
scripts/bench_kit/setup_bench_env.sh --dry-run --with-silero --with-qwen --download whisper-large-v3,qwen3-asr-1.7b
# 2) 설치: venv 약 550 MB + 모델 3.08 GB (large-v3) + 4.08 GB (Qwen3-ASR-1.7B). 인터넷은 이 단계에서만 필요
scripts/bench_kit/setup_bench_env.sh --with-silero --with-qwen --download whisper-large-v3,qwen3-asr-1.7b

# 3) 실행 (bench.env가 오프라인 모드와 경로를 잡아준다)
source ./bench.env
"$BENCH_PY" scripts/bench_asr.py --audio ~/회의오디오.m4a --start 600 --duration 900 \
  --models mlx-community/whisper-large-v3-mlx mlx-community/Qwen3-ASR-1.7B-bf16 \
  --language-mode auto-region --prompt-style frame+list --no-download --out benchmarks/run1-auto
```

결과는 `benchmarks/run1-auto/`의 `summary.md` (시간, 환각 필터, 루프), `comparison.md` (side-by-side), `vocabulary.md` (용어 적중), `numbers.md` (숫자/가격/날짜).

## 결과 가져오기와 정리

```bash
tar -czf bench-results.tar.gz benchmarks && scp bench-results.tar.gz alice@main-mac.local:~/   # 전사 텍스트도 회의 내용이다: 외부에 올리지 않는다
rm -rf ~/mcap-bench ~/회의오디오.m4a ~/bench-kit.tar.gz                                      # 끝나면 전부 삭제
```

옵션 요약: `--with-qwen` (Qwen 벤치용 패키지), `--with-silero` (운영과 같은 VAD), `--download` (`whisper-large-v3`, `qwen3-asr-1.7b`, `whisper-large-v3-turbo`), `--silero-file 경로` (오프라인), `--python 경로`, `--dry-run`.
