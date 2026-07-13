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

Orca에서 작업이 독립적인 2개 이상의 갈래로 나뉘면, Claude는 `$teammode`(Codex 한 프로세스가
멤버를 저글링) 대신 **진짜 병렬 Codex 터미널**을 띄웁니다. Orca의 네이티브 오케스트레이션이
작업 배정과 완료 보고를 추적합니다:

```bash
# 갈래마다 워커 터미널 하나 (현재 워크트리 공유)
orca terminal create --worktree active --title "worker-api" --command "codex" --json
orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 60000 --json

# 작업 생성 + 배정 (--inject 가 작업 지시문과 라이프사이클 프리앰블을 codex에 주입)
orca orchestration task-create --spec "<자기완결적 작업 지시문>" --json
orca orchestration dispatch --task <task_id> --to <handle> --inject --json

# 수거 루프 — 워커가 끝나면 worker_done, 막히면 escalation/decision_gate 메시지가 옴
orca orchestration check --wait --types worker_done,escalation,decision_gate --timeout-ms 570000 --json
```

- 완료 신호가 텍스트 토큰이 아니라 **`worker_done` 메시지**라서 감지가 확실합니다.
- 워커가 질문하면(`decision_gate`) Claude가 `orca orchestration reply`로 답합니다.
- `worker_done`이 와도 Claude가 **직접 검증**한 뒤에만 수락합니다 (기존 검증 원칙 동일).
- 독립된 체크아웃이 필요하면 `orca worktree create --name <part> --agent codex --json` 으로
  워크트리 단위 워커도 만들 수 있습니다.

## 안에 뭐가 들어있나요?

- **`SKILL.md`** — Claude가 따르는 지휘 절차 (이 파일이 스킬의 두뇌)
- **`REFERENCE.md`** — 백엔드별 pane 제어, 완료 토큰, 복구, 검증 경계에 대한 세부 운영 참고
- **`scripts/codex-pane.sh`** — 터미널 칸을 제어하는 작은 스크립트. tmux/orca/herdr을
  자동 감지하며, 스코프마다(창/워크트리/탭) Codex 칸 하나만 관리하고, 몇 번을 호출해도
  안전(idempotent)합니다:

  ```
  codex-pane.sh doctor            실행 환경·codex·LazyCodex 설정 점검
  codex-pane.sh start [프롬프트]   칸 만들고 codex 실행 (이미 있으면 재사용)
  codex-pane.sh send "<글>"        codex 입력창에 붙여넣고 전송
  codex-pane.sh peek [줄수]        최근 출력 보기 (기본 60줄)
  codex-pane.sh status            BUSY(작업중) | IDLE(대기) | BLOCKED(herdr) | NO_PANE(없음)
  codex-pane.sh wait "<패턴>" [초] 그 패턴이 나올 때까지 기다리기
  codex-pane.sh wait-idle [초]     codex가 멈출 때까지 기다리기
  codex-pane.sh keys <키...>       키 입력 (Escape, Enter, C-c ...)
  codex-pane.sh focus             codex 칸을 화면에 드러내기 (tmux/orca)
  codex-pane.sh stop              codex 중단하고 칸 닫기
  codex-pane.sh backend           활성 백엔드 출력 (tmux | herdr | orca)
  ```

  환경변수: `LAZYCODEX_BACKEND=tmux|herdr|orca` 로 감지를 덮어쓰고,
  `LAZYCODEX_PANE_NAME=<이름>` 으로 이름별 pane 여러 개를 병행 관리합니다.

## 알아두면 좋은 점

- `start [프롬프트]`는 먼저 `codex` TUI가 뜰 때까지 기다린 뒤 프롬프트를 전달합니다.
  (orca에서는 네이티브 `tui-idle` 신호로 대기) 셸 인자 quoting 문제로 긴 요청이 깨지는 일을 줄이기 위한 방식입니다.
- `$ulw-loop`의 완료 토큰은 짧게(30자 미만) — 화면에서 줄바꿈되면 감지를 못 합니다.
- orca에서 `peek`는 TUI 화면을 읽는 특성상 상태줄이 뭉개질 수 있습니다 — 작업중/대기 판단은
  `status`(네이티브 프로브)를 믿으세요.
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
