#!/bin/sh
# Roamtty: records what an AI coding agent is doing as options of its tmux session, which the app reads.
# Usage: agent-hook.sh <agent> <event> [tmux session], with the agent's hook JSON on stdin. Never fails the agent.
# Claude Code and Codex pass the JSON keys this reads in snake_case, Grok in camelCase.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/home/linuxbrew/.linuxbrew/bin:/snap/bin"
agent=$1
event=$2
session=$3
# Grok's hooks are global: only a Grok the app started (through ~/.roamtty/grok) reports.
[ "$agent" != grok ] || [ "$ROAMTTY_AGENT" = grok ] || exit 0
# A Claude Code session sent to the background (/bg, or the agents view) runs on outside tmux. Its hooks report to the
# tmux session named in its settings; with older settings, to the pane whose recorded session it resumes.
[ -n "$TMUX_PANE" ] || [ "$agent" = claude ] || exit 0
in_pane=${TMUX_PANE:+1}
input=$(cat 2>/dev/null)
# A Grok subagent's events are not its session's.
case "$agent:$input" in grok:*'"subagentType"'*) exit 0 ;; esac

# The string value of a JSON key (or of one of "a|b"), cleaned for one line: escapes undone, "|" and control characters gone, shortened.
field() {
  printf '%s' "$input" | sed -nE "s/.*\"($1)\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\2/p" | head -n 1 |
    sed -E 's/\\[nrt]/ /g; s/\\u[0-9a-fA-F]{4}//g; s/\\(["\\/])/\1/g' | tr '|' '/' | tr -d '\000-\037' | cut -c1-"${2:-160}"
}

get() { tmux show-options -qv -t "$TMUX_PANE" "$1" 2>/dev/null; }
put() { tmux set-option -q -t "$TMUX_PANE" "$1" "$2" 2>/dev/null; }

if [ -z "$in_pane" ] && [ -n "$session" ]; then
  tmux has-session -t "=$session" 2>/dev/null || exit 0
  TMUX_PANE="=$session:"
elif [ -n "$in_pane" ]; then
  # Kept past the session's end: a background session that resumed it still reports by it.
  [ "$agent" != claude ] || put @roamtty_session "$(field session_id 64)"
else
  # The session a background Claude Code resumed is in its command line ("--resume …/<id>.jsonl"); the hook may run
  # under a shell or two below it.
  pid=$PPID resumed=
  for _ in 1 2 3 4; do
    [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null || break
    resumed=$(ps -ww -o args= -p "$pid" 2>/dev/null | sed -nE 's/.*--resume[= ]+([^ ]*\/)?([0-9a-fA-F-]{36})(\.jsonl)?( .*)?$/\2/p')
    [ -z "$resumed" ] || break
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  [ -n "$resumed" ] || exit 0
  TMUX_PANE=$(tmux list-panes -a -F '#{pane_id} #{@roamtty_session}' 2>/dev/null | awk -v id="$resumed" '$2 == id { print $1; exit }')
  [ -n "$TMUX_PANE" ] || exit 0
fi

# state|since|agent|tool|detail; "since" keeps the time the state began while it repeats.
record() {
  now=$(date +%s)
  case "$(get @roamtty_agent)" in "$1|"*) now=$(get @roamtty_agent | cut -d '|' -f 2) ;; esac
  put @roamtty_agent "$1|$now|$agent|$2|$3"
}

# Claude Code runs several sessions for one tmux session once it has background jobs: the one in the pane and any number
# outside it. Codex and Grok have one session per pane.
if [ "$agent" = claude ]; then
  me=$(field session_id 64)
  if [ -z "$in_pane" ]; then
    # A job does not speak for a pane that now runs another agent.
    case "$(get @roamtty_agent | cut -d '|' -f 3)" in ''|claude) ;; *) exit 0 ;; esac
    case "$event" in
      # Spare processes start before any task, and a job starting says nothing about the pane.
      start) exit 0 ;;
      # A job's end leaves the pane's options. Stopped mid-turn, nothing else would say that the work is over.
      end)
        if [ "$(get @roamtty_owner)" = "$me" ]; then
          case "$(get @roamtty_agent)" in working\|*|waiting\|*) record idle "" "" ;; esac
        fi
        exit 0 ;;
    esac
  fi
  case "$event" in
    start|prompt|tool|post|ask) put @roamtty_owner "$me" ;;
    # Only the session that reported last says the work stopped or asks for anything: the one left in the pane notifies
    # while a job works.
    stop|notify)
      owner=$(get @roamtty_owner)
      [ -z "$owner" ] || [ "$owner" = "$me" ] || exit 0 ;;
  esac
fi

case "$event" in
  start)
    for option in @roamtty_worked @roamtty_reply; do tmux set-option -u -q -t "$TMUX_PANE" "$option" 2>/dev/null; done
    record idle "" "" ;;
  prompt)
    # Claude Code also submits "<task-notification>…" itself when a background task ends: that is no task of the user's.
    task=$(field prompt 200)
    case "$task" in "<"*) ;; *) put @roamtty_task "$task" ;; esac
    # A turn starts: the time it began, for how long it worked once it stops. A turn that waited for background work
    # (see stop) goes on when that work ends and wakes the agent.
    case "$task:$(get @roamtty_agent)" in "<"*:working\|*) ;; *) put @roamtty_turn "$(date +%s)" ;; esac
    for option in @roamtty_worked @roamtty_reply; do tmux set-option -u -q -t "$TMUX_PANE" "$option" 2>/dev/null; done
    record working "" "" ;;
  tool)
    tool=$(field 'tool_name|toolName' 40)
    detail=$(field command 120)
    [ -n "$detail" ] || detail=$(field 'file_path|filePath|path' 120)
    [ -n "$detail" ] || detail=$(field pattern 120)
    [ -n "$detail" ] || detail=$(field url 120)
    [ -n "$detail" ] || detail=$(field description 120)
    # Codex edits files with a patch as its command: the file it changes says more.
    case "$tool" in
      apply_patch) detail=$(printf '%s' "$detail" | sed -nE 's/^\*\*\* Begin Patch \*\*\* (Add|Update|Delete) File: ([^ ]+).*/\2/p') ;;
    esac
    record working "$tool" "$detail" ;;
  post)
    # The finished tool stays shown while the agent works on, until the next tool, a new prompt or the turn's end:
    # most tools end within a second, too quickly for the app to see them otherwise.
    current=$(get @roamtty_agent)
    record working "$(printf '%s' "$current" | cut -d '|' -f 4)" "$(printf '%s' "$current" | cut -d '|' -f 5)" ;;
  ask)
    # Codex asks for permission with a PermissionRequest hook.
    tool=$(field 'tool_name|toolName' 40)
    detail=$(field command 120)
    [ -n "$detail" ] || detail=$(field description 120)
    record waiting "$tool" "$detail" ;;
  notify)
    # Agents also notify when idle for a minute (Grok after a turn that reported no end too); a request for permission
    # waits, idleness settles. Claude Code's older notifications only say so in their message.
    kind=$(field 'notification_type|notificationType' 40)
    # Not while background work is to wake it (see stop): the agent only looks idle.
    case "$kind" in idle_prompt) [ "$(get @roamtty_agent | cut -d '|' -f 4)" = Background ] || record idle "" ""; exit 0 ;; esac
    case "$kind:$(field message 200)" in
      permission_prompt:*|*ermission*|*pprov*)
        # The message is generic: the tool about to run says more.
        current=$(get @roamtty_agent)
        tool=$(printf '%s' "$current" | cut -d '|' -f 4)
        if [ -n "$tool" ]; then record waiting "$tool" "$(printf '%s' "$current" | cut -d '|' -f 5)"
        else record waiting "" "$(field message 120)"; fi ;;
    esac ;;
  stop)
    # The start of the turn's answer, for the session list; all three agents pass it to their Stop hook.
    reply=$(field 'last_assistant_message|lastAssistantMessage' 400)
    [ -z "$reply" ] || put @roamtty_reply "$reply"
    # Claude Code and Grok list the background work still running (shells, monitors, subagents), which wakes the
    # agent when it ends: the turn is not over yet. The first task says what it waits for.
    tasks=$(printf '%s' "$input" | sed -nE 's/.*"(background_tasks|backgroundTasks)"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{([^}]*).*/\2/p' | head -n 1)
    if [ -n "$tasks" ]; then
      input="{$tasks}"
      detail=$(field command 120)
      [ -n "$detail" ] || detail=$(field description 120)
      record working Background "$detail"
      exit 0
    fi
    # How long the turn worked, in seconds; Claude Code shows it as "Worked for …".
    turn=$(get @roamtty_turn)
    case "$turn" in ''|*[!0-9]*) ;; *) put @roamtty_worked "$(( $(date +%s) - turn ))" ;; esac
    record idle "" "" ;;
  end)
    for option in @roamtty_agent @roamtty_task @roamtty_turn @roamtty_worked @roamtty_reply @roamtty_owner; do
      tmux set-option -u -q -t "$TMUX_PANE" "$option" 2>/dev/null
    done ;;
esac
exit 0
