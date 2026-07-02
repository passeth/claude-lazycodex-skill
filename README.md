# claude-lazycodex-skill

**Claude가 지휘자, Codex가 실무자.** 두 AI를 한 tmux 화면에서 협업시키는 [Claude Code](https://claude.com/claude-code) 스킬입니다.

Claude에게 일을 시키면, Claude가 옆 칸(tmux pane)에 [Codex](https://developers.openai.com/codex)를 띄우고
[LazyCodex](https://github.com/code-yeongyu/lazycodex)라는 강력한 작업 도구(`$ulw-loop`, `$start-work`, `$teammode` 등)로
실제 코딩을 시킵니다. Claude는 그동안 진행 상황을 지켜보고, Codex가 물어보면 답해주고, 다 됐다고 하면
**직접 빌드·테스트를 돌려서 진짜 됐는지 확인**한 뒤 결과를 알려줍니다.

```
┌─ tmux 창 하나 ────────────────────────────────────────────┐
│  Claude (지휘자)              │  Codex + LazyCodex (실무자)  │
│  • 어떤 명령을 쓸지 판단      │  $ulw-loop "..."             │
│  • Codex에게 작업 전달        │  → 계획·코드수정·테스트      │
│  • 지켜보고, 막히면 풀어줌    │  → 끝날 때까지 반복          │
│  • 직접 검증 (git diff, 빌드) │                              │
└───────────────────────────────┴──────────────────────────────┘
        왼쪽 칸  ◄── codex-pane.sh 로 제어 ──►  오른쪽 칸
```

## 왜 쓰나요?

- **Codex의 LazyCodex 하네스는 강력합니다** — 프로젝트 기억, 계획 수립, "진짜 끝날 때까지" 도는 실행 루프, 팀 모드까지.
- 하지만 혼자 두면 방향을 잃거나 "다 됐다"고 착각할 수 있습니다.
- 그래서 **Claude를 위에 얹어** 방향을 잡고, 결과를 검증하게 했습니다.
- 별도 프로그램 없이 **그냥 tmux 화면 한 칸**으로 두 모델이 협업합니다.

## 준비물

1. **Claude Code**를 **tmux 안에서** 실행 (스킬이 옆 칸을 띄우기 때문)
2. **[Codex CLI](https://developers.openai.com/codex)** 설치 + 로그인 (터미널에서 `codex` 실행되면 OK)
3. **[LazyCodex](https://github.com/code-yeongyu/lazycodex)** 설치:
   ```bash
   npx lazycodex-ai install
   ```
4. **tmux** (3.x 이상)

## 설치

Claude Code 스킬 폴더에 그대로 복사하면 끝입니다:

```bash
git clone https://github.com/passeth/claude-lazycodex-skill.git \
  ~/.claude/skills/lazycodex
chmod +x ~/.claude/skills/lazycodex/scripts/codex-pane.sh
```

다음번 Claude Code를 켜면 자동으로 인식됩니다. (`/skills` 로 확인 가능)

## 사용법

**tmux 안에서** Claude Code를 켜고, 그냥 평소처럼 말하면 됩니다:

- `codex한테 시켜서 ulw-loop로 이 버그 고쳐줘`
- `lazycodex로 이 기능 계획부터 세워줘`
- `codex teammode로 이 리팩토링 돌려줘`

그러면 Claude가 알아서:

1. **점검** — tmux·codex·LazyCodex 준비됐는지 확인
2. **명령 고르기** — 작업 성격에 맞는 Codex 명령 선택:

   | 이럴 때 | Codex 명령 | 끝난 신호 |
   | --- | --- | --- |
   | 코딩 전에 계획부터 | `$ulw-plan "..."` | `plans/` 에 계획 파일 생성 |
   | 이미 있는 계획 실행 | `$start-work <계획>` | `ORCHESTRATION COMPLETE` |
   | 될 때까지 알아서 (목표 모드) | `$ulw-loop "..." --completion-promise=토큰` | 그 토큰이 출력됨 |
   | 여러 갈래 병렬 작업 | `$teammode` | 팀 리더 요약 |

3. **전달 → 지켜보기 → 답하기** — Codex가 질문하면 Claude가 판단해서 답하거나, 사용자 결정이 필요하면 물어봄
4. **직접 검증** — Codex의 "다 됐어요"를 그냥 믿지 않고 `git diff`·빌드·테스트를 실제로 돌려 확인
5. **보고** — 뭐가 바뀌었는지, 검증 결과, 빠진 부분까지 정리

작업이 끝나도 Codex 칸은 열어두니 직접 들여다볼 수 있습니다.

## 안에 뭐가 들어있나요?

- **`SKILL.md`** — Claude가 따르는 지휘 절차 (이 파일이 스킬의 두뇌)
- **`scripts/codex-pane.sh`** — tmux 칸을 제어하는 작은 스크립트. 창마다 Codex 칸 하나만 관리하며, 몇 번을 호출해도 안전(idempotent)합니다:

  ```
  codex-pane.sh start [프롬프트]   칸 만들고 codex 실행 (이미 있으면 재사용)
  codex-pane.sh send "<글>"        codex 입력창에 붙여넣고 전송
  codex-pane.sh peek [줄수]        최근 출력 보기 (기본 60줄)
  codex-pane.sh status            BUSY(작업중) | IDLE(대기) | NO_PANE(없음)
  codex-pane.sh wait "<패턴>" [초] 그 패턴이 나올 때까지 기다리기
  codex-pane.sh wait-idle [초]     codex가 멈출 때까지 기다리기
  codex-pane.sh stop              codex 중단하고 칸 닫기
  ```

## 알아두면 좋은 점

- `$ulw-loop`의 완료 토큰은 짧게(30자 미만) — 화면에서 줄바꿈되면 감지를 못 합니다.
- Codex가 한 작업을 **사용자 확인 없이 커밋하지 않습니다.**
- Codex가 위험한 작업(파일 삭제, 설치, 네트워크 등)을 요청하면 자동 승인하지 않고 사용자에게 물어봅니다.
- 간단한 일회성 Codex 질문용은 아닙니다 — 그건 가벼운 `/codex` 계열 스킬을 쓰세요.

## 만든 배경 / 크레딧

[@code-yeongyu](https://github.com/code-yeongyu)님의 [LazyCodex](https://github.com/code-yeongyu/lazycodex)
위에 얹은 오케스트레이션 레이어입니다. LazyCodex는
[oh-my-openagent (OmO)](https://github.com/code-yeongyu/oh-my-openagent)를 Codex용 에이전트 하네스로 패키징한 프로젝트입니다.
이 스킬은 독립적인 지휘 레이어이며 위 프로젝트들과 공식 제휴 관계는 없습니다.

## 라이선스

MIT — [LICENSE](LICENSE) 참고.
