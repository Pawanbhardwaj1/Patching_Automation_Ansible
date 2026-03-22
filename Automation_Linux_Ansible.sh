#!/bin/bash
##########################################################
########### --- 1. Configuration & Paths --- #############
##########################################################
TEAMS_WEBHOOK_URL="https://yourcompany.webhook.office.com/..." 
EMAIL_ADMIN="admin@example.com"                                
LOG_DIR="/tmp/log/automation_logs"
#LOG_FILE="$LOG_DIR/automation_$(date +%F).log"
LOG_FILE="$LOG_DIR/automation_$(date +'%Y-%m-%d_%H%M%S').log"
DIFF_DIR="$LOG_DIR/diffs"
SNAPSHOT_DIR="$LOG_DIR/snapshots"
LOCK_FILE="/tmp/prodbot.lock"
SERVER_LIST=""

# Ensure directory structure exists
mkdir -p "$LOG_DIR" "$DIFF_DIR" "$SNAPSHOT_DIR"
sudo chown -R $(whoami):$(whoami) "$LOG_DIR" "$DIFF_DIR" "$SNAPSHOT_DIR"
# Styling & Emojis
CYAN=$(tput setaf 6); BOLD=$(tput bold); RESET=$(tput sgr0)
YELLOW=$(tput setaf 3); GREEN=$(tput setaf 2); RED=$(tput setaf 1)
MAGENTA=$(tput setaf 5)

# Function to log messages with CR Number
log_message() {
  local cr_tag="${CR_NUMBER:-NO_CR}"
  echo "$(date +'%Y-%m-%d %H:%M:%S') [$cr_tag] - $1" | tee -a "$LOG_FILE"
}

# Notification (Teams & Email)
notify() {
    local msg="$1"
    local cr_info="${CR_NUMBER:-NOT_SET}"
    local user_name=$(whoami)

    # Teams Webhook
    if [[ -n "$TEAMS_WEBHOOK_URL" ]]; then
        curl -s -H "Content-Type: application/json" -d "{
            \"@type\": \"MessageCard\", \"themeColor\": \"0076D7\", \"summary\": \"Alert\",
            \"sections\": [{ \"activityTitle\": \"📢 $msg\", \"facts\": [{\"name\": \"User\", \"value\": \"$user_name\"}, {\"name\": \"CR\", \"value\": \"$cr_info\"}] }]
        }" "$TEAMS_WEBHOOK_URL" > /dev/null
    fi
}

# Handle Forceful Exit
force_exit_handler() {
    echo -e "\n${RED}${BOLD}⚠️ WARNING: Forceful exit detected! Sending alerts...${RESET}"
    local msg="⚠️ ALERT: Automation was FORCEFULLY EXITED by user: $(whoami) [CR: ${CR_NUMBER:-NOT_SET}]"
    notify "$msg"
    echo "Terminated by $(whoami) at $(date)." | mail -s "🚨 FORCEFUL EXIT | CR: ${CR_NUMBER:-N/A}" "$EMAIL_ADMIN"
    rm -f "$LOCK_FILE"
    exit 1
}
trap 'force_exit_handler' SIGINT SIGTERM

install_dependencies() {
    echo -e "${CYAN}🔍 Checking system dependencies...${RESET}"
    # 1. Identify Local Package Manager
    if command -v dnf &>/dev/null; then
        PKGMGR="dnf"
        # Wait for RHEL background updates
        while fuser /var/lib/dnf/metadata_lock.pid >/dev/null 2>&1; do 
            echo -e "${YELLOW}⏳ DNF is busy. Waiting 5s...${RESET}"; sleep 5 
        done
        [[ ! -f /etc/yum.repos.d/epel.repo ]] && sudo dnf install -y epel-release
        MAIL_PKG="mailx"
    elif command -v apt-get &>/dev/null; then
        PKGMGR="apt-get"; MAIL_PKG="mailutils"
    else
        PKGMGR="zypper"; MAIL_PKG="mailx"
    fi
    # 2. Install Required Packages
    for dep in "parallel" "curl" "$MAIL_PKG"; do
        cmd=$dep; [[ "$dep" =~ mail ]] && cmd="mail"
        if ! command -v "$cmd" &>/dev/null; then
             echo -e "${YELLOW}📦 Installing $dep...${RESET}"
             sudo $PKGMGR install -y "$dep"
        fi
    done
    # 3. Install Ansible Collections (Replaces your manual step)
    echo -e "${CYAN}📚 Verifying Ansible Collections...${RESET}"
    ansible-galaxy collection install community.general --upgrade &>/dev/null

    # 4. Remote Ansible Environment Setup (Fixes the remote_tmp warning)
    if [[ -n "$SERVER_LIST" ]]; then
        echo -e "${CYAN}🏗️  Configuring remote Ansible temp directories on fleet...${RESET}"
        local inv=$(generate_inventory)
        # Create directory with 1777 (Sticky bit) to allow multi-user access safely
        ansible target_servers -i "$inv" -m file -a "path=/tmp/.ansible-root/tmp state=directory mode=1777" --become &>/dev/null
        rm -f "$inv"
    else
        echo -e "${YELLOW}⚠️  Skipping remote directory setup: Server list is empty.${RESET}"
    fi
    # Silence GNU Parallel Citation Notice automatically
    mkdir -p "$HOME/.parallel"
    touch "$HOME/.parallel/will-cite"
}

check_uptime() {
    log_message "--- Uptime ---"
    if [[ -z "$SERVER_LIST" ]]; then
        log_message "Server list is empty. Please enter servers first."
        return
    fi
    for server in $SERVER_LIST; do
	    echo "######################################################"
		echo ""
        log_message "Checking uptime for $server..."
		echo ""
		echo "######################################################"
        ssh -o ConnectTimeout=5 "$server" "uptime" 2>&1 | tee -a "$LOG_FILE"
        if [[ $? -ne 0 ]]; then
            log_message "Error connecting to $server. Skipping."
        fi
    done
    log_message "--- Uptime check completed. ---"
}

# Function to check filesystem utilization
check_filesystem_utilization() {
    log_message "--- Checking Filesystem Utilization for Servers ---"
    if [[ -z "$SERVER_LIST" ]]; then
        log_message "Server list is empty. Please enter servers first."
        return
    fi
    for server in $SERVER_LIST; do
	    echo "######################################################"
		echo ""
        log_message "Checking filesystem utilization for $server..."
		echo ""
		echo "######################################################"
        ssh -o ConnectTimeout=5 "$server" "df -h" 2>&1 | tee -a "$LOG_FILE"
        if [[ $? -ne 0 ]]; then
            log_message "Error connecting to $server. Skipping."
        fi
    done
    log_message "--- Filesystem utilization check complete. ---"
}
check_ssh_connectivity() {
    log_message "--- Verifying SSH Connectivity ---"
    [[ -z "$SERVER_LIST" ]] && { echo "No servers to check."; return; }
    
    local servers=($SERVER_LIST)
	echo "######################################################"
	echo ""
    echo -e "${YELLOW}🔍 Checking SSH on ${#servers[@]} servers...${RESET}"
	echo ""
    echo "######################################################"
    for s in "${servers[@]}"; do
        printf "${CYAN}%-20s${RESET}: " "$s"
        # The core logic you provided:
        ssh -q -o ConnectTimeout=3 -o BatchMode=yes "$s" "echo OK" &>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}CONNECTED${RESET}"
        else
            echo -e "${RED}FAILED${RESET}"
            log_message "Connectivity failed for $s"
        fi
    done
}


##########################################################
#### --- 2. Core Functions (Ansible Integrated) --- ######
##########################################################

generate_inventory() {
    local inv_file="/tmp/ansible_inventory_$$.ini"
    echo "[target_servers]" > "$inv_file"
    for s in $SERVER_LIST; do echo "$s" >> "$inv_file"; done
    echo "$inv_file"
}

run_checks() {
    local check_type="$1" # "Pre-Patching" or "Post-Patching"
    local cr_tag="${CR_NUMBER:-N/A}"
    local user_name=$(whoami)
    local timestamp=$(date +%F_%H%M%S)
    local inv=$(generate_inventory)
    
    local filename="CR${cr_tag}_${check_type// /_}_${user_name}_${timestamp}.html"
    local report_path="$LOG_DIR/$filename"

    log_message "--- Running Ansible $check_type ---"
    
    ansible-playbook -i "$inv" /home/ansible/playbooks/check_report.yml \
        --extra-vars "cr_number=$cr_tag snapshot_dir=$SNAPSHOT_DIR report_path=$report_path check_type='$check_type'" &>> "$LOG_FILE"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ $check_type HTML Report Generated: $filename${RESET}"
        # Email with Attachment
        local subject="$user_name | $filename | CR: $cr_tag"
        echo "Attached is the $check_type report." | mail -s "$subject" -A "$report_path" "$EMAIL_ADMIN"
        notify "$check_type report generated by $user_name."
        
        # Trigger Delta Check if Post-Patching
        [[ "$check_type" == "Post-Patching" ]] && compare_reports
    else
        echo -e "${RED}❌ $check_type Failed.${RESET}"
    fi
    rm -f "$inv"
}
compare_reports() {
    log_message "--- Starting Delta Comparison ---"
    local cr_tag="${CR_NUMBER:-N/A}"
    local alert_found=false
    local timestamp=$(date +%F_%H%M%S)
    local delta_report="$DIFF_DIR/Delta_CR${cr_tag}_${timestamp}.html"

    # HTML Header for the Delta Report
    echo "<html><head><style>
        body { font-family: sans-serif; }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 10px; border: 1px solid #ddd; text-align: left; }
        th { background-color: #f4f4f4; }
        .mismatch { color: red; font-weight: bold; }
        .match { color: green; }
    </style></head><body>
    <h2>⚖️ Delta Analysis: CR $cr_tag</h2>
    <table><tr><th>Server</th><th>Status</th><th>Metric Differences (Pre vs Post)</th></tr>" > "$delta_report"

    for server in $SERVER_LIST; do
        local pre_file="$SNAPSHOT_DIR/${server}_Pre-Patching.json"
        local post_file="$SNAPSHOT_DIR/${server}_Post-Patching.json"

        # Check if both snapshots exist before comparing
        if [[ ! -f "$pre_file" || ! -f "$post_file" ]]; then
            echo "<tr><td>$server</td><td>⚠️ MISSING</td><td>One or both snapshots missing.</td></tr>" >> "$delta_report"
            continue
        fi

        # Extract only critical metrics to ignore 'uptime' noise
        local pre_metrics=$(grep -E "pkg_count|disk_usage" "$pre_file" | tr -d '", ')
        local post_metrics=$(grep -E "pkg_count|disk_usage" "$post_file" | tr -d '", ')

        if [[ "$pre_metrics" != "$post_metrics" ]]; then
            alert_found=true
            # Generate a readable diff string
            local diff_out=$(diff <(echo "$pre_metrics") <(echo "$post_metrics") | grep -E "^<|^>")
            echo "<tr><td>$server</td><td class='mismatch'>❌ MISMATCH</td><td><pre>$diff_out</pre></td></tr>" >> "$delta_report"
            log_message "ALERT: Metric drift detected on $server"
        else
            echo "<tr><td>$server</td><td class='match'>✅ OK</td><td>No critical changes.</td></tr>" >> "$delta_report"
        fi
    done

    echo "</table></body></html>" >> "$delta_report"

    # --- Notifications & Alerts ---
    if [ "$alert_found" = true ]; then
        local subject="$(whoami) | DELTA_ALERT | CR: $cr_tag"
        notify "🚨 DELTA ALERT: Post-check mismatches found for CR $cr_tag!"
        echo "Please review the attached Delta Report for CR $cr_tag." | mail -s "$subject" -A "$delta_report" "$EMAIL_ADMIN"
    else
        notify "✅ Delta check passed for CR $cr_tag. Systems are consistent."
    fi
}
patch_servers() {
    log_message "--- Starting Ansible-Driven Patching ---"
    [[ -z "$SERVER_LIST" ]] && { log_message "Server list empty."; return; }

    # 1. Create a temporary Ansible Inventory file
    local ANSIBLE_INVENTORY="/tmp/ansible_inventory_$$.ini"
    echo "[target_servers]" > "$ANSIBLE_INVENTORY"
    echo "$SERVER_LIST" | tr ' ' '\n' >> "$ANSIBLE_INVENTORY"

    # 2. Define the Playbook Path (Ensure this file exists!)
    local PLAYBOOK_PATH="/home/ansible/playbooks/patch.yml"
	# --- Dry Run Logic ---
    read -p "Do you want to run a Dry Run (Check Mode)? [y/N]: " dry_choice
    local extra_args=""
    if [[ "$dry_choice" =~ ^[Yy]$ ]]; then
        extra_args="--check"
        echo -e "${YELLOW}🔍 Running in DRY RUN mode...${RESET}"
    fi

    if [[ ! -f "$PLAYBOOK_PATH" ]]; then
        log_message "❌ ERROR: Ansible Playbook not found at $PLAYBOOK_PATH"
        return 1
    fi

    echo -e "${YELLOW}🚀 Launching Ansible Playbook for CR: $CR_NUMBER...${RESET}"
    echo -e "${YELLOW}🚀 Launching Ansible Playbook for CR: $CR_NUMBER...${RESET}"
    
    # 3. Execute Ansible
    # We use --extra-vars to pass the CR Number into the playbook for logging
    ansible-playbook -i "$ANSIBLE_INVENTORY" "$PLAYBOOK_PATH" \
        --extra-vars "cr_number=$CR_NUMBER" \
        --become --become-method=sudo &>> "$LOG_FILE"

    local exit_code=$?

    # 4. Handle Results
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}${BOLD}✅ Ansible patching completed successfully!${RESET}"
        notify "Ansible patching successful for CR $CR_NUMBER."
        echo "Patching finished for $CR_NUMBER via Ansible." | mail -s "🚀 Patching Success: $CR_NUMBER" "$EMAIL_ADMIN"
    else
        echo -e "${RED}${BOLD}❌ ERROR: Ansible Playbook failed with exit code $exit_code${RESET}"
        notify "Ansible patching FAILED for CR $CR_NUMBER. Check $LOG_FILE"
        echo "Ansible patching encountered errors for $CR_NUMBER." | mail -s "🚨 Patching Failed: $CR_NUMBER" "$EMAIL_ADMIN"
    fi

    # Cleanup
    rm -f "$ANSIBLE_INVENTORY"
}

reboot_servers() {
    log_message "--- Starting Ansible-Parallel Reboot & Wait ---"
    [[ -z "$SERVER_LIST" ]] && { log_message "Server list empty."; return; }

    local inv=$(generate_inventory)
    local cr_tag="${CR_NUMBER:-N/A}"

    echo -e "${YELLOW}🔄 Initiating Reboots via Ansible...${RESET}"
    echo -e "${CYAN}Note: Ansible will wait for each host to become reachable again.${RESET}"

    # We use the 'reboot' module which handles the shutdown and the wait-for-up
    # -f 10 allows 10 reboots to happen in parallel
    ansible target_servers -i "$inv" -m reboot -a \
        "reboot_timeout=600 connect_timeout=10 test_command=uptime" \
        -f 10 --become &>> "$LOG_FILE"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}${BOLD}✅ All servers have rebooted and are back online.${RESET}"
        
        # Verification: Get fresh uptime for the log
        echo -e "${CYAN}📊 Current Uptime Status:${RESET}"
        ansible target_servers -i "$inv" -m shell -a "uptime -p" --become | grep -A 1 "SUCCESS" | tee -a "$LOG_FILE"
        
        notify "Parallel reboot and health-check completed for CR $cr_tag."
        echo "Reboot cycle finished for $cr_tag." | mail -s "$(whoami) | REBOOT_COMPLETE | CR: $cr_tag" "$EMAIL_ADMIN"
    else
        echo -e "${RED}${BOLD}❌ ERROR: Some servers failed to reboot or reconnect.${RESET}"
        notify "ALERT: Reboot cycle encountered failures for CR $cr_tag."
    fi

    rm -f "$inv"
}

refresh() {
    log_message "--- Starting Repo Refresh ---"
    [[ -z "$SERVER_LIST" ]] && { log_message "Server list empty."; return; }

    local inv=$(generate_inventory)
    echo -e "${YELLOW}🔄 Refreshing repositories...${RESET}"

    # 1. Clear Apt locks first (prevents the 'stuck' issue on Ubuntu)
    echo -e "${CYAN}🔓 Checking for package manager locks...${RESET}"
    ansible target_servers -i "$inv" -m shell -a "killall apt apt-get 2>/dev/null; rm -f /var/lib/dpkg/lock*" --become &>> "$LOG_FILE"

    # 2. Run APT update (Will only succeed on Ubuntu/Debian)
    echo -e "${MAGENTA}📦 Updating Ubuntu/Debian nodes...${RESET}"
    ansible target_servers -i "$inv" -m apt -a "update_cache=yes" --become &>> "$LOG_FILE"

    # 3. Run DNF update (Will only succeed on RHEL/CentOS)
    echo -e "${MAGENTA}📦 Updating RHEL/CentOS nodes...${RESET}"
    ansible target_servers -i "$inv" -m dnf -a "update_cache=yes" --become &>> "$LOG_FILE"

    echo -e "${GREEN}✅ Repo refresh cycle complete. Check $LOG_FILE for specific host results.${RESET}"
    notify "Repo refresh attempt finished for CR $CR_NUMBER."
    rm -f "$inv"
}
check_logs() {
    log_message "--- Starting Deep Patch & Kernel Audit ---"
    [[ -z "$SERVER_LIST" ]] && { echo -e "${RED}No servers to check.${RESET}"; return; }

    local inv=$(generate_inventory)
    echo -e "${CYAN}🔍 Querying OS databases via Audit Helper...${RESET}"

    # Use the 'script' module to run the local helper on remote nodes
    ansible target_servers -i "$inv" -m script -a "/home/ansible/playbooks/audit_helper.sh" --become | while read -r line; do
        if [[ "$line" == *"REBOOT_REQUIRED"* ]]; then
            echo -e "${RED}${BOLD}$line ⚠️${RESET}"
        elif [[ "$line" == *"RESULT: OK"* ]]; then
            echo -e "${GREEN}$line ✅${RESET}"
        elif [[ "$line" == *"FAILED"* ]]; then
             echo -e "${RED}$line${RESET}"
        else
            echo -e "$line"
        fi
    done | tee -a "$LOG_FILE"

    rm -f "$inv"
}
get_cr_number() {
    read -p "Enter CR Number: " CR_INPUT
    export CR_NUMBER="$CR_INPUT"
    log_message "CR Number Set: $CR_NUMBER"
}

get_server_list() {
    echo "Enter hostnames (Ctrl+D to end):"
    SERVER_LIST=$(cat)
}

##########################################################
################ --- 3. Main Menu --- ####################
##########################################################
get_stats() {
    # If SERVER_LIST is a space-separated string, word count is more accurate
    local total=$(echo "$SERVER_LIST" | wc -w)
    echo -e "\033[1;33mSTATUS: $total Servers Configured | Log: $LOG_FILE\033[0m"
}

# Main patching menu
install_dependencies
notify "User $(whoami) has initialized the Bridge. 👨‍🚀"

while true; do
    clear
    echo "========================================"
    echo " Preparing Menu ....Please wait ✋...."
    echo "========================================="
    sleep 1
    clear
    echo "====================================================="
    echo "   Welcome to Server Patch Management Menu 😀..."
    echo "====================================================="
    clear
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${CYAN}${BOLD}   🚀 WELCOME, ${BOLD}$(whoami)${CYAN}${BOLD} TO THE PROD COMMAND CENTER 🚀        ${RESET}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo "-----------------------------------------------------"
    echo -e "${BOLD}MAIN MENU:${RESET}"
    echo "01.➡️ Enter Server List"
	echo "02.➡️ Enter CR Number"
    echo "03.➡️ SSH Connectivity"
    echo "04.➡️ Check Ping Status"
    echo "05.➡️ Uptime"
    echo "06.➡️ Check Filesystem Utilization"
    echo "07.➡️ Run Patching Pre-checks"
    echo "08.➡️ Refresh Respositories"
    echo "09.➡️ Linux Patching"
    echo "10.➡️ Check Patch Completion Status"
    echo "11.➡️ Run Patching Post-checks"
    echo "12.➡️ Compare Patching Pre-checks and Post-checks"
    echo "13.➡️ Reboot"
    echo "14.➡️ Exit"
    echo "-----------------------------------------------------"

    if [ -n "$SERVER_LIST" ]; then
        total=$(echo "$SERVER_LIST" | wc -w)
        echo "Servers in list: $SERVER_LIST"
    else
        total=0
        echo -e "${RED}🚨 WARNING 🚨: No servers found. Please use option 1.${RESET}"
    fi

    echo -e "${MAGENTA}----------------------------------------------------------${RESET}"
    echo -e "${MAGENTA}📊 Current Servers Count : $total Servers | 🆔 CR: ${CR_NUMBER:-N/A}${RESET}"
    echo -e "${MAGENTA}📝 Session Log: $LOG_FILE${RESET}"
    echo -e "${MAGENTA}----------------------------------------------------------${RESET}\n"
    
   read -p "Enter your choice: " choice
    case $choice in
        1)  
            get_server_list 
            notify "User $(whoami) updated the Server List."
            ;;
        2)  
            get_cr_number 
            # 📧 Special Email for CR Entry
            local mail_body="Automation started by user: $(whoami)\nCR Number: $CR_NUMBER\nStatus: CR Verified. CR Locked Automation Menu options are now UNLOCKED for this session."
            echo -e "$mail_body" | mail -s "🔓 Automation Unlocked: CR $CR_NUMBER" "$EMAIL_ADMIN"
            notify "CR $CR_NUMBER verified. Menu options 3-13 are now available."
            ;;
        3|4|5|6|7|8|9|10|11|12|13)
            # 🛡️ Safety Gate: Check if CR Number is present
            if [[ -z "$CR_NUMBER" ]]; then
                echo -e "${RED}${BOLD}❌ ERROR: Access Denied.${RESET}"
                echo -e "${YELLOW}Please enter a Change Request (CR) Number (Option 2) before proceeding.${RESET}"
                notify "ALERT: User $(whoami) attempted to access Option $choice without a CR Number."
            else
                # Execute based on the specific choice
                case $choice in
                    3)  
                        check_ssh_connectivity 
                        notify "Connectivity check completed for CR $CR_NUMBER." 
                        ;;
                    4)  
                        for s in $SERVER_LIST; do ping -c 1 -W 1 "$s" >/dev/null && echo "$s: UP" || echo "$s: DOWN"; done
                        notify "Ping status check performed for CR $CR_NUMBER."
                        ;;
                    5)  
                        check_uptime 
                        notify "Uptime report generated for CR $CR_NUMBER."
                        ;;
                    6)  
                        check_filesystem_utilization 
                        notify "FS Utilization check performed for CR $CR_NUMBER."
                        ;;
                    7)  
                        # 📧 Email + Teams
						
                        run_checks "Pre-Patching" "Pre-Patching Checks"
                        echo "Pre-checks completed for CR $CR_NUMBER. Results saved to $PRECHECK_FILE" | mail -s "📊 Pre-Check Report: CR $CR_NUMBER" "$EMAIL_ADMIN"
                        notify "Pre-patching checks completed for CR $CR_NUMBER."
                        ;;
                    8)  
                        refresh 
                        notify "Repositories refreshed on servers for CR $CR_NUMBER."
                        ;;
                    9)  
                        # 📧 Email + Teams
                        patch_servers 
                        echo "Patching process finished for CR $CR_NUMBER. Please review the Summary Report." | mail -s "🚀 Patching Execution: CR $CR_NUMBER" "$EMAIL_ADMIN"
                        notify "Patching sequence executed for CR $CR_NUMBER."
                        ;;
                    10) 
                        check_logs 
                        notify "Logs reviewed for CR $CR_NUMBER."
                        ;;
                    11) 
                        # 📧 Email + Teams
                        run_checks "Post-Patching" "Post-Patching Checks"
                        echo "Post-checks completed for CR $CR_NUMBER. Results saved to $POSTCHECK_FILE" | mail -s "📊 Post-Check Report: CR $CR_NUMBER" "$EMAIL_ADMIN"
                        notify "Post-patching checks completed for CR $CR_NUMBER."
                        ;;
                    12) 
                        # 📧 Email + Teams
                        compare_reports 
                        echo "Comparison report generated for CR $CR_NUMBER. Check $DIFF_DIR for details." | mail -s "⚖️ Comparison Report: CR $CR_NUMBER" "$EMAIL_ADMIN"
                        notify "Pre/Post comparison completed for CR $CR_NUMBER."
                        ;;
					13) 
                       # 📧 Email + Teams
                        reboot_servers 
                        echo "Reboot and verification cycle finished for CR $CR_NUMBER." | mail -s "🔄 Reboot Cycle Complete: CR $CR_NUMBER" "$EMAIL_ADMIN"
                        notify "Parallel reboot and health-check completed for CR $CR_NUMBER."
                         ;;
                   
                esac
            fi
            ;;
        14)
            notify "User $(whoami) exited the Automation Bridge."
            log_message "Exiting script. Have a Great Day !!! Goodbye! 👋😀"
            exit 0
            ;;
        *) 
            echo -e "${RED}Oops! Invalid option selected ❌. Please enter a number from 1 to 14.${RESET}" 
            ;;
    esac
    echo
    read -p "Press Enter to continue..."
done
