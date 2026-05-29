#!/usr/bin/env bash

set -eou pipefail

## Argument Parsing ##

SKIP_COUNT=0
ASK=1

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --skip)
      if [[ -n "${2:-}" ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
        SKIP_COUNT="$2"
        shift 2
      else
        echo "Error: --skip requires a positive integer argument." >&2
        exit 1
      fi
      ;;
    --all)
      ASK=0
      shift
      ;;
    *)
      echo "Unknown parameter passed: $1" >&2
      exit 1
      ;;
  esac
done

## Setup ##

CURR_DIR=$(pwd)
ARB_DIR="$CURR_DIR/lib/l10n"

ARB_PFX="lang"
if [[ "$CURR_DIR" == *"empathetech_flutter_ui" ]]; then
  ARB_DIR="$CURR_DIR/lib/src/l10n"
  ARB_PFX="efui_lang"
fi

SRC_FIL="$ARB_DIR/${ARB_PFX}_en_US.arb"

# Build a map of lang -> file, skipping duplicates (keep first)
declare -A LANG_FILE
for f in "$ARB_DIR"/${ARB_PFX}_*.arb; do
  [[ -f "$f" ]] || continue
  locale=$(basename "$f" .arb)
  locale=${locale#${ARB_PFX}_}
  base=${locale%%_*}
  base=${base,,}
  
  if [[ -z "${LANG_FILE[$base]:-}" ]]; then
    LANG_FILE[$base]="$f"
  fi
done
unset LANG_FILE["en"]

# Initialize tracking array early so the trap can safely read it
declare -A FAILS  # FAILS[lang]="line1,line2,..."

## Report Function & Trap ##

print_report() {
  echo; echo "=== L10N AUDIT FAILURES ==="
  if [[ ${#FAILS[@]} -eq 0 ]]; then
    echo "Looks great! No issues found."
    return
  fi

  for lang in "${!FAILS[@]}"; do
    # remove possible duplicate line numbers and sort
    IFS=',' read -r -a arr <<< "${FAILS[$lang]}"
    uniq_sorted=$(printf '%s\n' "${arr[@]}" | awk '!seen[$0]++' | sort -n | paste -sd, -)
    echo "$lang: $uniq_sorted"
  done
}

# Catch SIGINT (Ctrl+C) && print anything we have
trap 'echo -e "\n[!] Printing partial results..."; print_report; exit 130' SIGINT

## Preamble ##

echo "Reminder: we're not looking for exact matches, but for meaning matches";
echo "Especially since the translate-shell tool is... imperfect.";

echo ""; echo "Flag big misses, then manually review those lines. False failures are very possible. False successes less so.";

echo ""; echo "Enter (CR/empty) marks a group success"
echo "If there are lines that need review, enter a CSV of the language codes (e.g. ar,zh)"

echo ""; read -p "Press enter to start..."

## Make it so ##

# Gather keys (line number and key) from English source
mapfile -t LINES < <(grep -nE '"[a-z]{1,4}[^"]*"[[:space:]]*:' "$SRC_FIL" || true)
if [[ ${#LINES[@]} -eq 0 ]]; then
  echo "No entries found in $SRC_FIL" >&2
  exit 1
fi

# Apply the skip count
if [[ "$SKIP_COUNT" -gt 0 ]]; then
  if [[ "$SKIP_COUNT" -ge "${#LINES[@]}" ]]; then
    echo "Skip count ($SKIP_COUNT) is greater than or equal to the number of entries (${#LINES[@]}). Nothing to audit." >&2
    exit 0
  fi
  LINES=("${LINES[@]:SKIP_COUNT}")
fi

JSON_LINE_REGEX='^[[:space:]]*"([^"]+)"[[:space:]]*:[[:space:]]*"(.*)"[[:space:]]*,?[[:space:]]*$'
for entry in "${LINES[@]}"; do
  line_num="${entry%%:*}"
  line_content="${entry#*:}"

  # Get key and English source value
  if [[ "$line_content" =~ $JSON_LINE_REGEX ]]; then
    key="${BASH_REMATCH[1]}"
    en_value="${BASH_REMATCH[2]}"
  else
    echo "Warning: Could not parse line $line_num in $SRC_FIL: $line_content" >&2
    continue
  fi  
  clear; echo "$key: $en_value"; echo ""

  if [ $ASK == 1 ]; then
    IFS= read -r -n 1 -p "Translate? " DEW_IT
    echo ""

    case "$DEW_IT" in
      [nN\ ]) continue ;;
      *) ;; # "continue" below ;)
    esac
  fi

  # Get translated values and their translate-shell results
  for base in "${!LANG_FILE[@]}"; do
    file="${LANG_FILE[$base]}"

    # find the key line in that file
    match_line=$(grep -nE "\"${key}\"[[:space:]]*:" "$file" || true)
    if [[ -z "$match_line" ]]; then
      # no translation for this key in that language
      echo "$base: (missing)"; echo ""
      continue
    fi

    other_line_num="${match_line%%:*}"
    other_line_content="${match_line#*:}"
    
    if [[ "$other_line_content" =~ $JSON_LINE_REGEX ]]; then
      other_val="${BASH_REMATCH[2]}"
    else
      other_val="[parsing failed]"
    fi
    
    # use translate-shell to translate into English (auto-detect source)
    trans_out=$(trans -b :en "$other_val" 2>/dev/null || printf '[translate failed]')
    echo "$base: $trans_out"; echo ""
  done

  # Prompt user 
  read -r -p "> " user_in

  # trim whitespace
  user_trimmed="$(echo "$user_in" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  if [[ -z "$user_trimmed" ]]; then
    continue
  fi

  # Mark failures
  IFS=',' read -r -a err_langs <<< "$user_trimmed"
  for raw in "${err_langs[@]}"; do
    lang_tmp="${raw//[[:space:]]/}"
    lang="${lang_tmp,,}"
    [[ -z "$lang" ]] && continue

    if [[ -n "${LANG_FILE[$lang]:-}" ]]; then
      file="${LANG_FILE[$lang]}"
      match_line=$(grep -nE "\"${key}\"[[:space:]]*:" "$file" || true)
      if [[ -n "$match_line" ]]; then
        other_line_num="${match_line%%:*}"
        if [[ -z "${FAILS[$lang]:-}" ]]; then
          FAILS[$lang]="$other_line_num"
        else
          FAILS[$lang]="${FAILS[$lang]},$other_line_num"
        fi
      else
        # if key missing in that lang file, record the english line number as reference
        if [[ -z "${FAILS[$lang]:-}" ]]; then
          FAILS[$lang]="$line_num"
        else
          FAILS[$lang]="${FAILS[$lang]},$line_num"
        fi
      fi
    else
      echo "Warning: language '$lang' not tracked or not present (skipping)" >&2
    fi
  done
done

## Final Output ##

# Call the report function manually upon successful completion
print_report