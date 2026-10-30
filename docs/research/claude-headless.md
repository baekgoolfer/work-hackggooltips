# `claude -p` 헤드리스 호출 (조사 요약)

> 조사 요약. 검증은 CLI 2.1.278에서 `claude.ai` 로그인(`authMethod: claude.ai`)으로 했다. 구현은 `pipeline/mcap/note.py`와 `pipeline/mcap/calendar_lookup.py`다.
> 실제 usage-limit/overage/529 응답은 계정에서 재현하지 못했고 mock(가짜 자격 증명, 임시 HOME)으로 문서 기준 형태를 시뮬레이션했다.

## 핵심
- 깨끗한 env에서 동작하려면 **`HOME`, `USER`, `PATH`(/usr/bin 포함) 셋이 모두 필요**. 하나라도 빠지면 "Not logged in"처럼 보인다(로그아웃과 구별 불가).
- **`--bare`는 OAuth/키체인을 읽지 않아 구독 인증이 깨진다** (API key만 허용). 사용 금지. 문서상 향후 `-p`가 기본 `--bare`가 될 수 있어 `~/.local/bin/claude`의 auto-update를 끈 상태로 고정하고, `claude update` 뒤에는 재검증(모델 해석, not-logged-in 시뮬레이션, 실제 노트 1건).
- 격리 플래그 `--tools "" --disable-slash-commands --safe-mode --setting-sources "" --strict-mcp-config --mcp-config '{"mcpServers":{}}' --no-session-persistence`: CLAUDE.md/hooks/plugins/skills/MCP 영향이 사라지고(카나리 테스트) OAuth는 유지됨.
- 모델 alias(2.1.278): `opus`→`claude-opus-5`, `sonnet`→`claude-sonnet-5`, `fable`→`claude-fable-5-1`. 고정 id `claude-opus-5-5`는 이 CLI에서 실패. `claude update` ≥2.1.280이면 opus가 Opus 5.5로 바뀔 수 있음. `fable`은 사용 크레딧이 과금될 수 있다는 문서 근거로 파이프라인에서 제외.
- `--output-format stream-json --verbose`만 `assistant.error`, `rate_limit_event`, init의 `apiKeySource`를 준다. 일반 `json`은 이런 신호를 숨기고 `result.subtype`이 에러에도 `success`로 남으며 모든 실패가 exit 1. → 줄 단위로 JSONL 파싱(thinking signature 때문에 이벤트가 큼).
- 성능: 합성 KO/EN 트랜스크립트 2,896단어(134KB stdin) → effort high 145s, medium 121s(~72 output tok/s, 노트 길이가 지연을 결정), 모든 심은 사실 보존, 잘림 없음. 출력 상한 64K 토큰. 프롬프트는 반드시 **stdin**.

## 과금 모드 보증
- `claude auth status`만으로는 과금 경로를 증명할 수 없음(`ANTHROPIC_API_KEY=fake`에서도 `authMethod=claude.ai` 출력). → **env 허용목록**(HOME, USER, PATH, LANG만) + 호출별 단언(init `apiKeySource=="none"`, 모든 `modelUsage` provider `firstParty`).
- `ANTHROPIC_API_KEY/AUTH_TOKEN/BASE_URL` 유입은 먼저 분 단위 재시도 hang으로, 다음으로 `billing_mode_violation`으로 나타남. `ANTHROPIC_BASE_URL`은 자격 증명을 그 URL로 보내기도 함.
- **계정에 Extra usage가 켜져 있으면**(`hasExtraUsageEnabled: true`, `overageStatus: allowed`): 한도 소진 시 CLI가 사용 크레딧(돈)으로 계속할 수 있다. 사후에만 `rate_limit_event.isUsingOverage`로 감지 가능 → SPEC 13.3 과금 가드(marker 기록, 이후 노트 중단) 적용. `NOTE_STOP_ON_OVERAGE`로 정한다(기본: 중단).

## 실패 분류 (is_error / api_error_status 기준, subtype·exit code 단독 사용 금지)
usage_limit(429 + rejected) → 재시도 안 함, `resetsAt` 기록, transcript 보존 / Opus 전용 한도 → sonnet 즉시 재시도 / rate_limited(plain 429) → 30–60s 후 폴백 1회 / overloaded(500/502/503/529, assistant.error server_error) → 폴백 1회 / auth(401/403, 'Not logged in', 'Login expired') → 재시도 없음 / billing → 재시도 없음·위반 처리 / model_unavailable(404) → 폴백 1회 / truncated(stop_reason≠end_turn) → 실패 / timeout·crash(결과 없음) → 1회 재시도. 구현·검증은 `pipeline/mcap/note.py`(10/10 캡처 출력 검증, 실제 호출 1건 성공: claude-opus-5, 5.1s).

## 캘린더 커넥터 (선택)
claude.ai Google Calendar 커넥터는 헤드리스에서 **단일 턴으로는 비동기 커넥터 fetch 경쟁 때문에 불안정**하고, **2-turn stream-json 세션**으로만 동작 확인(`pipeline/mcap/calendar_lookup.py`). 원시 tool_result를 Python에서 파싱해 겹침 판정(모델 산문 사용 금지), `events` 키 없으면 빈 창, `--safe-mode/--strict-mcp-config`는 이 세션에서 쓰지 않음. 미검증: `--disallowedTools`로 Gmail/Drive/Slack/Notion/캘린더 쓰기 차단(아이디어). 모든 실패는 창 제목/플랫폼 폴백.

## 라이브 검증 필요
LaunchAgent(`gui/<uid>`)에서 `claude auth status`/`-p`가 Keychain 프롬프트 없이 동작하는지(필요 시 Always Allow), 실제 한국어/영어 회의 노트 품질, `claude update` 이후 재검증, 캘린더 조회가 앱 하위 Process에서도 되는지.
