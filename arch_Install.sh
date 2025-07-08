#!/bin/bash

set -e

# Colors
RED="\e[31m"
GREEN="\e[32m"
CYAN="\e[36m"
RESET="\e[0m"

# Fancy header
clear
echo -e "${CYAN}"
figlet -c Adventuncation || echo -e "\n     Adventuncation"
echo -e "${RESET}"
echo -e "${GREEN}Welcome! Installing Arch Linux with style...${RESET}"
echo

# Function: multi-column numbered select
select_from_list() {
  local -n options=$1
  local prompt="$2"
  local cols=${3:-3}
  local per_col=$(( (${#options[@]} + cols - 1) / cols ))
  local i

  echo -e "${CYAN}$prompt${RESET}"
  for ((i = 0; i < ${#options[@]}; i++)); do
    printf "%3d) %-20s" $((i+1)) "${options[$i]}"
    if (( (i+1) % per_col == 0 )); then echo; fi
  done
  echo

  local choice
  while true; do
    read -rp "Choose (1-${#options[@]}): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#options[@]})); then
      REPLY=${options[$((choice-1))]}
      break
    else
      echo -e "${RED}Invalid input. Try again.${RESET}"
    fi
  done
}

# Function: Timezone selection
select_timezone() {
  mapfile -t regions < <(timedatectl list-timezones | cut -d'/' -f1 | sort -u | grep -v -e '^$' -e '^Etc$')
  select_from_list regions "Select your region:" 3
  local selected_region="$REPLY"

  mapfile -t cities < <(timedatectl list-timezones | grep "^$selected_region/")
  select_from_list cities "Select your city/zone:" 3
  TIMEZONE="$REPLY"
}

# Main execution flow hereon... (placeholder)
select_timezone

echo -e "\n${GREEN}Selected Timezone: $TIMEZONE${RESET}"

# ... Rest of your full installer script here (disk selection, etc.)
