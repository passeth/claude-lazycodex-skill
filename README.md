# claude-lazycodex-skill

**Claude가 지휘자, Codex가 실무자.** 두 AI를 한 화면에서 협업시키는 [Claude Code](https://claude.com/claude-code) 스킬입니다.
**tmux, [herdr](https://herdr.dev), [Orca IDE](https://www.onorca.dev)** 세 환경을 지원합니다.

Claude에게 일을 시키면, Claude가 옆 칸(터미널 pane)에 [Codex](https://developers.openai.com/codex)를 띄우고
[LazyCodex](https://github.com/code-yeongyu/lazycodex)라는 강력한 작업 도구(`$ulw-loop`, `$start-work`, `$teammode` 등)로
실제 코딩을 시킵니다. Claude는 그동안 진행 상황을 지켜보고, Codex가 물어보면 답해주고, 다 됐다고 하면
**직접 빌드·테스트를 돌려서 진짜 됐는지 확인**한 뒤 결과를 알려줍니다.

```
┌─ 한 화면 (tmux 창 / Orca 워크트리 / herdr 탭) ───────────────┐
│  Claude (지휘자)              │  Codex + LazyCodex (실무자)  │
│  • 어떤 명령을 쓸지 판단      │  $ulw-loop "..."             │
│  • Codex에게 작업 전달        │  → 계획·코드수정·테스트      │
│  • 지켜보고, 막히면 풀어줌    │  → 끝날 때까지 반복          │
│  • 직접 검증 (git diff, 빌드) │                              │
└───────────────────────────────┴──────────────────────────────┘
        왼쪽 칸  ◄── codex-pane.sh 로 제어 ──►  오른쪽 칸
```

Orca IDE에서는 여기에 더해 **A2A 멀티 워커 모드**를 지원합니다 — Codex 터미널 여러 개를
병렬로 띄우고, Orca의 네이티브 오케스트레이션(task dispatch → `worker_done`)으로
작업을 분배·수거합니다.

## 왜 쓰나요?

- **Codex의 LazyCodex 하네스는 강력합니다** — 프로젝트 기억, 계획 수립, "진짜 끝날 때까지" 도는 실행 루프, 팀 모드까지.
- 하지만 혼자 두면 방향을 잃거나 "다 됐다"고 착각할 수 있습니다.
- 그래서 **Claude를 위에 얹어** 방향을 잡고, 결과를 검증하게 했습니다.
- 별도 프로그램 없이 **터미널 화면 한 칸**으로 두 모델이 협업합니다.

## 언제 쓰나요? (그리고 언제 안 써도 되나요)

이 스킬의 본질은 **Claude에게 LazyCodex 사용법을 가르치는 것**입니다. 터미널을 띄우는 건
tmux든 Orca든 원래 되는 일이지만, **어떤 하네스 명령을 골라야 하는지, 완료 토큰을 어떻게
잡아야 하는지, "다 됐다"를 어떻게 검증해야 하는지**는 Claude가 기본적으로 모릅니다.
그 지식이 `SKILL.md`에 들어 있습니다.

| 이런 상황 | 쓸 것 |
|---|---|
| Codex한테 짧은 질문 하나, 리뷰 한 번 | ❌ 이 스킬 아님 — 가벼운 `/codex` 계열을 쓰세요 |
| 코드를 실제로 짜야 하고, 될 때까지 자율로 돌리고 싶다 | ✅ **이 스킬** — 단일 pane + `$ulw-loop` (가장 흔한 경우) |
| 큰 기능이라 계획부터 세워야 한다 | ✅ **이 스킬** — `$ulw-plan` → 계획 검토 → `$start-work` |
| 갈래가 2~4개, 파일이 안 겹친다 (Orca) | ✅ **이 스킬의 A2A 모드** — 워커마다 하네스를 돌립니다 |
| 그냥 다른 에이전트에게 일을 넘기고 손 떼고 싶다 | ❌ Orca의 `orca-cli` 핸드오프를 쓰세요 |
| 하네스 없이 순수 codex 워커만 조율하면 된다 | ❌ Orca의 `orchestration` 스킬만으로 충분합니다 |

**Orca 자체 기능과의 관계.** Orca에는 이미 `orca-cli`(터미널·워크트리 제어)와
`orchestration`(작업 배정·`worker_done` 수거)이 있습니다. 그것들만으로도 codex 워커를 띄우고
조율할 수 있습니다 — **다만 그 워커는 "맨 codex"입니다.** 이 스킬은 그 위에 얹혀서,
Claude가 워커에게 **LazyCodex 하네스를 제대로 물려주도록** 만듭니다:

- 작업 성격에 맞는 하네스 명령 선택 (`$ulw-plan` / `$start-work` / `$ulw-loop`)
- `--completion-promise` 토큰 규칙 (30자 미만 — 넘으면 TUI에서 줄바꿈돼 감지 실패)
- `$` 접두사가 스킬 피커를 띄워 입력을 삼킬 때의 복구
- Codex의 "완료" 선언을 믿지 않고 Claude가 직접 빌드·테스트로 검증하는 경계

즉 **Orca = 배선, 이 스킬 = 하네스 운용법 + 검증 규율**입니다. 둘은 경쟁 관계가 아니라
층이 다르며, A2A 모드에서는 실제로 Orca의 오케스트레이션 위에서 하네스가 돌아갑니다.

## 준비물

1. **Claude Code**를 지원 환경 안에서 실행 (스킬이 옆 칸을 띄우기 때문):
   - **tmux** (3.x 이상) 안에서, 또는
   - **[Orca IDE](https://www.onorca.dev)** 터미널 안에서 (`orca` CLI + `jq` 필요 — Orca 터미널이면 기본 충족), 또는
   - **[herdr](https://herdr.dev)** 안에서 (`brew install herdr`)
2. **[Codex CLI](https://developers.openai.com/codex)** 설치 + 로그인 (터미널에서 `codex` 실행되면 OK)
3. **[LazyCodex](https://github.com/code-yeongyu/lazycodex)** 설치:
   ```bash
   npx lazycodex-ai install
   ```

## 설치

Claude Code 스킬 폴더에 그대로 복사하면 끝입니다:

```bash
git clone https://github.com/passeth/claude-lazycodex-skill.git \
  ~/.claude/skills/lazycodex
chmod +x ~/.claude/skills/lazycodex/scripts/codex-pane.sh
```

다음번 Claude Code를 켜면 자동으로 인식됩니다. (`/skills` 로 확인 가능)

설치 뒤 준비 상태를 확인할 수 있습니다:

```bash
~/.claude/skills/lazycodex/scripts/codex-pane.sh doctor
```

`doctor`는 실행 환경(tmux/orca/herdr 자동 감지), `codex` CLI, LazyCodex 플러그인
설정(`omo@sisyphuslabs`), 현재 Codex pane 상태를 점검합니다.

## 사용법

지원 환경 안에서 Claude Code를 켜고, 그냥 평소처럼 말하면 됩니다:

- `codex한테 시켜서 ulw-loop로 이 버그 고쳐줘`
- `lazycodex로 이 기능 계획부터 세워줘`
- `codex teammode로 이 리팩토링 돌려줘`
- (Orca에서) `orca 워커 3개로 a2a로 나눠서 돌려줘`

그러면 Claude가 알아서:

1. **점검** — `doctor`로 실행 환경·codex·LazyCodex 준비 상태 확인
2. **명령 고르기** — 작업 성격에 맞는 Codex 명령 선택:

   | 이럴 때 | Codex 명령 | 끝난 신호 |
   | --- | --- | --- |
   | 코딩 전에 계획부터 | `$ulw-plan "..."` | `plans/` 에 계획 파일 생성 |
   | 이미 있는 계획 실행 | `$start-work <계획>` | `ORCHESTRATION COMPLETE` |
   | 될 때까지 알아서 (목표 모드) | `$ulw-loop "..." --completion-promise=토큰` | 그 토큰이 출력됨 |
   | 여러 갈래 병렬 작업 (tmux/herdr) | `$teammode` | 팀 리더 요약 |
   | 여러 갈래 병렬 작업 (Orca) | A2A 멀티 워커 모드 (아래) | `worker_done` 메시지 |

3. **전달 → 지켜보기 → 답하기** — Codex가 질문하면 Claude가 판단해서 답하거나, 사용자 결정이 필요하면 물어봄
4. **직접 검증** — Codex의 "다 됐어요"를 그냥 믿지 않고 `git diff`·빌드·테스트를 실제로 돌려 확인
5. **보고** — 뭐가 바뀌었는지, 검증 결과, 빠진 부분까지 정리

작업이 끝나도 Codex 칸은 열어두니 직접 들여다볼 수 있습니다.

## Orca IDE: A2A 멀티 워커 모드

Orca에서 작업이 독립적인 2~4개 갈래로 나뉘면, Claude는 `$teammode`(Codex 한 프로세스가
멤버를 저글링) 대신 **진짜 병렬 Codex 터미널**을 띄웁니다. 그리고 **각 워커 안에서 LazyCodex
하네스가 돕니다** — 하네스의 자율성과 Orca의 확실한 완료 추적을 둘 다 가져갑니다.

```bash
# 1) 갈래마다 워커 터미널 하나 (MCP는 끄고 — 아래 주의사항 참고)
orca terminal create --worktree active --title "worker-api" \
  --command "codex -c 'mcp_servers={}'" --json

# 2) 준비 확인 — tui-idle만으로는 부족합니다 (아래 주의사항 참고)
orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 60000 --json
orca terminal show --terminal <handle> --json | jq -r '.result.terminal.preview'
#    "Context ... left" 가 보이면 준비됨 / "Sign in" 이 보이면 로그인 화면 → 디스패치 금지

# 3) 작업 생성 + 배정 — spec 안에 하네스 명령을 넣습니다
orca orchestration task-create --spec 'Step 1 - run exactly this in your composer:
$ulw-loop "<실제 작업>" --completion-promise="LCX_DONE_API"

Step 2 - once the harness prints LCX_DONE_API, send worker_done as your preamble instructs.' --json
orca orchestration dispatch --task <task_id> --to <handle> --inject --json

# 4) 수거 루프
orca orchestration check --wait --types worker_done,escalation,decision_gate --timeout-ms 570000 --json
```

**하네스와 `worker_done`은 충돌하지 않습니다** (실측 검증). `$ulw-loop`가 자기 완료 약속에
도달해 끝난 *뒤에* 워커가 완료 보고를 하는 순차 구조라, 루프가 중첩되지 않습니다.

- 워커가 질문하면(`decision_gate`) Claude가 `orca orchestration reply`로 답합니다.
- `worker_done`이 와도 Claude가 **직접 검증**한 뒤에만 수락합니다 (검증 원칙은 동일).
- 독립된 체크아웃이 필요하면 `orca worktree create --name <part> --agent codex --json`.
- 워커끼리 **같은 파일을 건드리지 않게** 갈래를 나누세요. 한 프로세스인 `$teammode`와 달리
  진짜 병렬이라 파일 충돌은 조율자 책임입니다.

### 실전에서 물린 것들 (Orca 한정)

- **MCP를 끄고 워커를 띄우세요.** Codex의 app-server는 launchd 기본값인 **fd 256개** 제한을
  물려받는데, stdio MCP 서버 하나하나가 파이프를 물고 있습니다. MCP를 잔뜩 문 워커를 몇 개
  병렬로 띄우면 app-server가 `Too many open files (os error 24)`로 고착되고, **codex 전체가
  안 뜹니다.** 복구는 app-server 프로세스를 죽이면 됩니다(다음 실행 때 자동 재생성).
- **`tui-idle`은 준비 상태를 보장하지 않습니다.** Codex의 **로그인 화면에서도 `ok=true`** 를
  반환합니다. 그 상태로 디스패치하면 작업 지시문이 로그인 프롬프트에 타이핑되고 증발하며,
  조율자는 오지 않을 `worker_done`을 영원히 기다립니다. 반드시 preview로 컴포저를 확인하세요.
- **조용한 워커 ≠ 느린 워커.** `worker_done`은 워커가 셸 명령을 띄워야 보낼 수 있어서, 워커의
  도구 실행이 깨지면 완료 신호가 영영 안 옵니다. 타임아웃을 "아직 일하는 중"으로 넘기지 말고
  터미널을 실제로 읽어 확인하세요.
- **알려진 미해결 이슈**: codex 내부에서 보낸 `worker_done`이 조율자 수신함에 도달하지 않는
  경우를 한 번 관측했습니다(CLI는 메시지 ID를 반환). 일반 셸에서 보낸 메시지는 정상 도착하므로
  배달 자체는 멀쩡합니다. 원인 미확정이라, **완료 메시지가 없다고 결과가 없는 게 아닙니다** —
  워커 터미널에 완료 토큰이 찍혔는지 확인하고 리포트 파일을 직접 거두세요.

## 멀티모델 팬: 워커마다 다른 두뇌 (opencodex)

팬마다 **다른 모델**을 태울 수 있습니다 — 설계는 강한 모델, 기계적 구현은 싼 모델,
리뷰는 다른 계열 모델. OpenAI 모델끼리는 `-m`만으로 되고, 비-OpenAI 모델(Kimi, DeepSeek 등)은
[opencodex](https://github.com/lidge-jun/opencodex) 프록시가 **필수**입니다:
codex 0.146부터 `wire_api = "chat"`이 제거되어 Responses API만 지원하는데, 대부분의
서드파티 API는 `/v1/responses`가 없기 때문입니다 (Moonshot 404 실측).

```bash
# 설치 (한 번): 프로바이더 추가 후 restart는 필수입니다 — 안 하면 조용히 OpenAI로 샙니다
npm i -g @bitkyc08/opencodex && ocx start
ocx provider add moonshot --api-key "$MOONSHOT_API_KEY" && ocx restart && ocx sync

# 워커마다 모델 지정 — LAZYCODEX_CODEX_ARGS로 주입
LAZYCODEX_PANE_NAME=worker-arch LAZYCODEX_CODEX_ARGS="-m gpt-5.5 -c mcp_servers={}" \
  codex-pane.sh start "..."
LAZYCODEX_PANE_NAME=worker-impl LAZYCODEX_CODEX_ARGS="-m moonshot/kimi-k3 -c mcp_servers={}" \
  codex-pane.sh start "..."
```

### 실전에서 물린 것들 (멀티모델 한정)

- **디스패치 전 `ocx health` 확인.** 프록시가 죽으면 라우팅된 팬 전부가 한꺼번에 죽는
  단일 장애점입니다. 팬이 살아있는 동안 `ocx stop`은 절대 금지 — codex 설정을 원복시켜
  발밑을 빼버립니다.
- **Orca는 `~/.codex/config.toml`을 계정 홈으로 복사**하면서 프록시 주입을 지웁니다.
  주입은 양쪽 모두: `env -u CODEX_HOME ocx sync` (원본) + `ocx sync` (계정 홈).
  라우팅이 이상하면 두 config에서 `openai_base_url`부터 grep 하세요.
- **`ocx sync --restart-codex`는 머신의 모든 codex app-server를 죽입니다** (ChatGPT.app
  포함). 다른 세션에 라이브 런이 있는지 확인하고 쓰세요.
- **라우팅 검증은 `ocx observe logs`.** `moonshot/kimi-k3`처럼 프로바이더 접두어가 찍히면
  정상, `openai/moonshot/kimi-k3`처럼 openai 뒤에 붙어 나오면 패스스루로 새는 중입니다.
  프로바이더 쪽 429/400이 찍혔다면 라우팅은 성공이고 문제는 업스트림(쿼터/과금)입니다.
- **deprecated 모델은 로스터에 넣지 마세요.** 시작 시 전환 다이얼로그가 떠서 디스패치한
  프롬프트를 삼킵니다. 다이얼로그 조작은 **숫자 텍스트 + Enter**가 가장 안전합니다
  (orca 백엔드 `keys`에 화살표/BSpace 매핑이 추가됐지만, 숫자는 매핑 공백과 무관합니다).

전체 절차와 세부 규칙은 `SKILL.md`의 "Multi-model panes (opencodex)" 섹션에 있습니다.

## 안에 뭐가 들어있나요?

- **`SKILL.md`** — Claude가 따르는 지휘 절차 (이 파일이 스킬의 두뇌)
- **`REFERENCE.md`** — 백엔드별 pane 제어, 완료 토큰, 복구, 검증 경계에 대한 세부 운영 참고
- **`scripts/codex-pane.sh`** — 터미널 칸을 제어하는 작은 스크립트. tmux/orca/herdr을
  자동 감지하며, 스코프마다(창/워크트리/탭) Codex 칸 하나만 관리하고, 몇 번을 호출해도
  안전(idempotent)합니다:

  ```
  codex-pane.sh doctor              실행 환경·codex·LazyCodex 설정 점검
  codex-pane.sh start [프롬프트]     칸 만들고 codex 실행 (이미 있으면 재사용)
  codex-pane.sh send "<글>"          codex 입력창에 붙여넣고 전송
  codex-pane.sh peek [줄수]          최근 출력 보기 (기본 60줄)
  codex-pane.sh status              BUSY(작업중) | IDLE(대기) | BLOCKED(herdr) | NO_PANE(없음)
  codex-pane.sh done-file <슬러그>   완료 표식 파일 경로 발급 (묵은 표식 삭제)
  codex-pane.sh wait-done <슬러그>   ★ 진짜 완료 신호 — codex가 표식을 touch할 때까지 대기
  codex-pane.sh wait "<패턴>" [초]   그 패턴이 나올 때까지 대기 (직접 타이핑한 토큰엔 쓰지 말 것)
  codex-pane.sh wait-idle [초]       codex가 멈출 때까지 대기
  codex-pane.sh keys <키...>         키 입력 (Escape, Enter, C-c ...)
  codex-pane.sh focus               codex 칸을 화면에 드러내기 (tmux/orca)
  codex-pane.sh stop                codex 중단하고 칸 닫기
  codex-pane.sh backend             활성 백엔드 출력 (tmux | herdr | orca)
  ```

  환경변수: `LAZYCODEX_BACKEND=tmux|herdr|orca` 로 감지를 덮어쓰고,
  `LAZYCODEX_PANE_NAME=<이름>` 으로 이름별 pane 여러 개를 병행 관리합니다.

## ⚠️ 반드시 알아야 할 3가지

**1. 완료는 화면 글자가 아니라 파일로 판단합니다.** 예전 방식(`wait "<완료토큰>"`)은 **거짓 완료**를
냅니다. codex는 긴 프롬프트를 여러 줄로 감싸 렌더하는데 **첫 줄에만 `›` 접두어**가 붙습니다. 완료 토큰이
뒷줄에 놓이면 **자기가 방금 보낸 프롬프트에 자기가 매칭**됩니다. 실측: 디스패치 6초 만에 "완료" 반환,
그때 codex는 아직 로딩 중이고 변경 파일 0건. 스킬이 "프롬프트를 자기완결적으로(=길게) 쓰라"고 하니
**권장대로 쓸수록 확실히 터집니다.** 그래서 이제 sentinel 파일을 씁니다:

```bash
DONE=$(codex-pane.sh done-file auth)
codex-pane.sh start "\$ulw-loop \"...\" --completion-promise=\"LCX_DONE_AUTH\"
When the work is complete and verified, run exactly: touch $DONE"
codex-pane.sh wait-done auth 570      # 0=완료 | 3=타임아웃 | 4=pane 죽음
```
파일은 화면 에코로 위조되지 않고, TUI 리드로우·스크롤백에도 안전하며, 백엔드 독립적입니다.

**2. `IDLE`은 `완료`가 아닙니다.** `status`는 이제 **BUSY 쪽으로 편향**돼 있습니다 — 화면에
`esc to interrupt`, `Working (…)`, `Waiting for agents` 중 하나라도 보이면 백엔드 프로브보다 우선합니다.
비대칭이 핵심입니다: 거짓 BUSY는 폴링 한 번 낭비지만, **거짓 IDLE은 codex가 쓰고 있는 트리를 덮어쓰게**
만듭니다. (orca의 `tui-idle`은 `$ulw-loop`가 서브에이전트를 팬아웃하는 동안 idle이라고 답합니다 — 화면이
맞고 프로브가 틀립니다.)

**3. codex 칸이 살아 있는 동안 레포 파일을 건드리지 마세요.** codex가 워킹트리의 소유자입니다.
실제 사고: 작업 도중 사용자가 요구사항을 바꿔 오케스트레이터가 파일을 고쳤더니, **옛 지시문을 들고 있던
codex가 그걸 "요구사항 위반"으로 보고 두 번 되돌렸습니다.** codex 잘못이 아니라 stale brief를 성실히
수행한 결과입니다. 커밋 직전에 겨우 잡았습니다. **방향을 바꾸려면 `stop` → 편집 → 재디스패치.**
긴 작업은 아예 격리된 체크아웃(`orca worktree create --agent codex`)에 맡기는 게 안전합니다.

## 알아두면 좋은 점

- `start [프롬프트]`는 먼저 `codex` TUI가 뜰 때까지 기다린 뒤 프롬프트를 전달합니다.
  (orca에서는 네이티브 `tui-idle` 신호로 대기) 셸 인자 quoting 문제로 긴 요청이 깨지는 일을 줄이기 위한 방식입니다.
- `--completion-promise`는 **계속 넘기세요** — 하네스가 "될 때까지" 돌게 만드는 장치입니다. 다만 그걸로
  **완료를 감지하지는** 마세요.
- **codex는 샌드박스 없이 돌고 프로젝트 env를 상속합니다.** 프로덕션 크레덴셜이 있는 레포에서
  "DB 건드리지 마라"는 프롬프트일 뿐 강제장치가 아닙니다. 그런 레포에 디스패치하기 전엔 사용자에게
  확인하고, 격리된 워크트리 + 비프로덕션 크레덴셜을 쓰세요.
- Codex가 한 작업을 **사용자 확인 없이 커밋하지 않습니다.**
- Codex가 위험한 작업(파일 삭제, 설치, 네트워크 등)을 요청하면 자동 승인하지 않고 사용자에게 물어봅니다.
- 간단한 일회성 Codex 질문용은 아닙니다 — 그건 가벼운 `/codex` 계열 스킬을 쓰세요.

## 참고한 설계

이 저장소는 [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc)의 운영 방식을 참고했습니다. 특히 setup/status/result 같은 작은 명령으로 실행 상태를 분리하고, Claude가 직접 코드를 만지는 대신 Codex 실행 경계와 검증 경계를 명확히 나누는 패턴을 반영했습니다.
Orca A2A 모드는 [stablyai/orca](https://github.com/stablyai/orca)의 공식 `orchestration` 스킬 컨벤션(task-create → dispatch --inject → check --wait, `worker_done` 권위)을 따릅니다.

## 만든 배경 / 크레딧

[@code-yeongyu](https://github.com/code-yeongyu)님의 [LazyCodex](https://github.com/code-yeongyu/lazycodex)
위에 얹은 오케스트레이션 레이어입니다. LazyCodex는
[oh-my-openagent (OmO)](https://github.com/code-yeongyu/oh-my-openagent)를 Codex용 에이전트 하네스로 패키징한 프로젝트입니다.
이 스킬은 독립적인 지휘 레이어이며 위 프로젝트들과 공식 제휴 관계는 없습니다.

## 라이선스

MIT — [LICENSE](LICENSE) 참고.
