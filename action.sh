#!/bin/bash

# Log file setup
ACTION_LOG="$HOME/service_actions_$(date +%Y%m%d).log"

# Set directory paths
INFO_PATH="$(dirname "$0")/Info"
DEPLOYMENT_SCRIPTS_PATH="$(dirname "$0")/deployment_scripts"
SERVERS_CONF="$INFO_PATH/servers.conf"

# SSH connection optimization
SSH_CONTROL_PATH="/tmp/ssh_mux_%h_%p_%r"
SSH_MUX_OPTS="-o ControlMaster=auto -o ControlPath=$SSH_CONTROL_PATH -o ControlPersist=1h"
SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 $SSH_MUX_OPTS"

# Temporary dir for remote scripts
REMOTE_TMP_DIR="/tmp/deployment_scripts"

# Available services
SERVICES=("binance" "kucoin" "gateio")

# Default values
SOURCE_DATACENTER=""
DEST_DATACENTER=""
SOURCE_VM_INPUT=""
MAX_PARALLEL_JOBS=2
SELECTED_SERVICE=""
NON_INTERACTIVE=false
VERBOSE=false

# Parse command-line arguments
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -s SOURCE_DC     Source datacenter name"
    echo "  -d DEST_DC       Destination datacenter name"
    echo "  -v VM_NUMBERS    Source VM numbers (comma-separated, e.g., '1,3,5' or 'all')"
    echo "  -p PARALLEL      Maximum parallel jobs (default: 2)"
    echo "  -r SERVICE       Service to migrate (binance, kucoin, or gateio)"
    echo "  -y               Non-interactive mode (skip confirmation prompts)"
    echo "  -V               Verbose mode"
    echo "  -h               Display this help message"
    echo
    echo "Example: $0 -s arvan -d cloudzy -v all -p 3 -r binance -y"
    exit 1
}

while getopts "s:d:v:p:r:yVh" opt; do
    case $opt in
        s)
            SOURCE_DATACENTER="$OPTARG"
            ;;
        d)
            DEST_DATACENTER="$OPTARG"
            ;;
        v)
            SOURCE_VM_INPUT="$OPTARG"
            ;;
        p)
            MAX_PARALLEL_JOBS="$OPTARG"
            ;;
        r)
            SELECTED_SERVICE="$OPTARG"
            ;;
        y)
            NON_INTERACTIVE=true
            ;;
        V)
            VERBOSE=true
            ;;
        h|*)
            usage
            ;;
    esac
done

# Function for logging
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local action=$1
    local server=$2
    local status=$3
    local action_name=$4
    
    # Use a fixed-width template format for perfect alignment
    if [[ -n "$status" ]]; then
        local icon="   "
        if [[ "$status" == "Started" ]]; then
            icon="──▶"
        elif [[ "$status" == "Completed" ]]; then
            icon="✅ "
        elif [[ "$status" == "Failed" ]]; then
            icon="❌ "
        fi
        
        # Truncate or pad strings to exact lengths for perfect alignment
        local action_str=$(printf "%-12.12s" "$action")
        local action_name_str=$(printf "%-20.20s" "$action_name")
        local server_str=$(printf "%-15.15s" "$server")
        
        # Create the log message with exact spacing and alignment
        printf "[%s] %s [Action %s] %-20s | Server: %-15s | STATUS: %s\n" \
            "$timestamp" "$icon" "$action_str" "$action_name_str" "$server_str" "$status" | tee -a "$ACTION_LOG"
    else
        # Simple log line for messages without structured format
        echo "[$timestamp] $1" | tee -a "$ACTION_LOG"
    fi
}

# Log section headers
log_header() {
    local header_text=$1
    local header_width=60
    local line=$(printf '%*s' "$header_width" | tr ' ' '-')
    local header=$(printf "|%*s%s%*s|" $(( (header_width - 2 - ${#header_text}) / 2 )) "" "$header_text" $(( (header_width - 2 - ${#header_text} + 1) / 2 )) "")
    
    echo "" | tee -a "$ACTION_LOG"
    echo "$line" | tee -a "$ACTION_LOG"
    echo "$header" | tee -a "$ACTION_LOG"
    echo "$line" | tee -a "$ACTION_LOG"
    echo "" | tee -a "$ACTION_LOG"
}

# Function to parse servers configuration
parse_servers_config() {
    if [ ! -f "$SERVERS_CONF" ]; then
        log "ERROR: Servers configuration file not found at $SERVERS_CONF"
        exit 1
    fi
    
    # Extract unique datacenters
    DATACENTERS=($(awk -F'|' '{print $1}' "$SERVERS_CONF" | sort | uniq))
}

# Function to get VM names for a specific datacenter
get_datacenter_vms() {
    local datacenter=$1
    awk -F'|' -v dc="$datacenter" '$1 == dc {print $2}' "$SERVERS_CONF"
}

# Function to get server details
get_server_details() {
    local datacenter=$1
    local vm_name=$2
    
    local details=$(awk -F'|' -v dc="$datacenter" -v vm="$vm_name" '$1 == dc && $2 == vm {print $0}' "$SERVERS_CONF")
    
    if [ -z "$details" ]; then
        log "ERROR: No details found for $datacenter $vm_name"
        return 1
    fi
    
    # Split details into array
    IFS='|' read -r DATACENTER VM_NAME IP HOST USERNAME PORT <<< "$details"
    return 0
}

# Function to establish SSH connection (open multiplexed connection)
setup_ssh_connection() {
    local user=$1
    local host=$2
    local port=$3
    local vm_name=$4
    
    # Check if connection is already established
    ssh -O check $SSH_MUX_OPTS -p $port $user@$host 2>/dev/null
    if [ $? -ne 0 ]; then
        log "Setting up SSH connection" "$vm_name" "Started" "SSH Connection"
        # Create a background connection that will persist
        ssh $SSH_OPTS -p $port -M -f -N $user@$host
        if [ $? -ne 0 ]; then
            log "Setting up SSH connection" "$vm_name" "Failed" "SSH Connection"
            return 1
        fi
        log "Setting up SSH connection" "$vm_name" "Completed" "SSH Connection"
    fi
    return 0
}

# Function to close SSH connection
close_ssh_connection() {
    local user=$1
    local host=$2
    local port=$3
    local vm_name=$4
    
    log "Closing SSH connection" "$vm_name" "Started" "SSH Connection"
    ssh -O exit $SSH_MUX_OPTS -p $port $user@$host 2>/dev/null
    log "Closing SSH connection" "$vm_name" "Completed" "SSH Connection"
}

# Function to copy specific deployment scripts based on selected service
copy_deployment_scripts() {
    local user=$1
    local host=$2
    local port=$3
    local vm_name=$4
    local service=$5
    
    # Create remote tmp directory in one shot
    ssh $SSH_OPTS -p $port $user@$host "mkdir -p $REMOTE_TMP_DIR"
    if [ $? -ne 0 ]; then
        log "Create remote directory" "$vm_name" "Failed" "Copy Scripts"
        return 1
    fi
    
    # Copy only the specific service scripts (faster than copying all scripts)
    log "Copying deployment scripts" "$vm_name" "Started" "Copy Scripts"
    
    # Check if the service scripts exist
    if [ ! -f "$DEPLOYMENT_SCRIPTS_PATH/deploy_all_${service}.sh" ] || \
       [ ! -f "$DEPLOYMENT_SCRIPTS_PATH/start_all_${service}.sh" ] || \
       [ ! -f "$DEPLOYMENT_SCRIPTS_PATH/stop_all_${service}.sh" ] || \
       [ ! -f "$DEPLOYMENT_SCRIPTS_PATH/purge_all_${service}.sh" ]; then
        log "Missing required scripts for service $service" "$vm_name" "Failed" "Copy Scripts"
        return 1
    fi
    
    # Copy service-specific scripts one by one (most reliable approach)
    scp $SSH_OPTS -P $port "$DEPLOYMENT_SCRIPTS_PATH/deploy_all_${service}.sh" "$user@$host:$REMOTE_TMP_DIR/"
    if [ $? -ne 0 ]; then
        log "Copy deploy script" "$vm_name" "Failed" "Copy Scripts"
        return 1
    fi
    
    scp $SSH_OPTS -P $port "$DEPLOYMENT_SCRIPTS_PATH/start_all_${service}.sh" "$user@$host:$REMOTE_TMP_DIR/"
    if [ $? -ne 0 ]; then
        log "Copy start script" "$vm_name" "Failed" "Copy Scripts"
        return 1
    fi
    
    scp $SSH_OPTS -P $port "$DEPLOYMENT_SCRIPTS_PATH/stop_all_${service}.sh" "$user@$host:$REMOTE_TMP_DIR/"
    if [ $? -ne 0 ]; then
        log "Copy stop script" "$vm_name" "Failed" "Copy Scripts"
        return 1
    fi
    
    scp $SSH_OPTS -P $port "$DEPLOYMENT_SCRIPTS_PATH/purge_all_${service}.sh" "$user@$host:$REMOTE_TMP_DIR/"
    if [ $? -ne 0 ]; then
        log "Copy purge script" "$vm_name" "Failed" "Copy Scripts"
        return 1
    fi
    
    # Make scripts executable
    ssh $SSH_OPTS -p $port $user@$host "chmod +x $REMOTE_TMP_DIR/*.sh"
    if [ $? -ne 0 ]; then
        log "Make scripts executable" "$vm_name" "Failed" "Copy Scripts"
        return 1
    fi
    
    log "Copying deployment scripts" "$vm_name" "Completed" "Copy Scripts"
    return 0
}

# Function to execute action with service-specific script
execute_action() {
    local action_num=$1
    local user=$2
    local host=$3
    local port=$4
    local target_path=$5
    local vm_name=$6
    local service=$7
    
    case $action_num in
        1)
            action_script="deploy_all_${service}.sh"
            action_name="Deploy ${service^} Service"
            ;;
        2)
            action_script="start_all_${service}.sh"
            action_name="Start ${service^} Service"
            ;;
        3)
            action_script="stop_all_${service}.sh"
            action_name="Stop ${service^} Service"
            ;;
        4)
            action_script="purge_all_${service}.sh"
            action_name="Purge ${service^} Service"
            ;;
        *)
            log "ERROR: Invalid action number: $action_num"
            return 1
            ;;
    esac
    
    log "$action_num" "$vm_name" "Started" "$action_name"
    
    # Execute the script on the remote machine (reusing connection)
    ssh $SSH_OPTS -p $port $user@$host "cd $target_path && $REMOTE_TMP_DIR/$action_script"
    local result=$?
    
    if [ $result -eq 0 ]; then
        log "$action_num" "$vm_name" "Completed" "$action_name"
    else
        log "$action_num" "$vm_name" "Failed" "$action_name"
        echo "ERROR: Action $action_num ($action_name) failed on $vm_name"
        return 1
    fi
}

# Process a single migration job
process_migration_job() {
    local job_number=$1
    local source_datacenter=$2
    local dest_datacenter=$3
    local source_vm_index=$4
    local service=$5
    local source_vms=("${@:6}")
    
    # Log job header
    log_header "Service Transfer Operation - Job $job_number"
    
    # Get the source VM name
    SOURCE_VM=${source_vms[$source_vm_index]}
    
    # Get source VM details
    if ! get_server_details "$source_datacenter" "$SOURCE_VM"; then
        log "ERROR: Failed to get details for source VM $SOURCE_VM in $source_datacenter"
        return 1
    fi
    
    SOURCE_USER=$USERNAME
    SOURCE_IP=$IP
    SOURCE_HOST=$HOST
    SOURCE_PORT=$PORT
    SOURCE_PATH="/home/$USERNAME/"
    
    # Generate destination VM name by replacing the datacenter name in the VM name
    local source_vm_number=$(echo "$SOURCE_VM" | sed "s/.*\([0-9]\+\).*/\1/")
    DEST_VM="cr${source_vm_number}${dest_datacenter}"
    
    # Get destination VM details
    if ! get_server_details "$dest_datacenter" "$DEST_VM"; then
        log "ERROR: Failed to get details for destination VM $DEST_VM in $dest_datacenter"
        return 1
    fi
    
    DEST_USER=$USERNAME
    DEST_IP=$IP
    DEST_HOST=$HOST
    DEST_PORT=$PORT
    DEST_PATH="/home/$USERNAME/"
    
    echo -e "\nJob #$job_number Configuration:"
    echo "Source: $source_datacenter - $SOURCE_VM ($SOURCE_HOST)"
    echo "Destination: $dest_datacenter - $DEST_VM ($DEST_HOST)"
    echo "Service: $service"
    
    # Setup SSH connections once for both source and destination
    setup_ssh_connection "$SOURCE_USER" "$SOURCE_HOST" "$SOURCE_PORT" "$SOURCE_VM"
    setup_ssh_connection "$DEST_USER" "$DEST_HOST" "$DEST_PORT" "$DEST_VM"
    
    # Copy service-specific deployment scripts to both servers
    copy_deployment_scripts "$SOURCE_USER" "$SOURCE_HOST" "$SOURCE_PORT" "$SOURCE_VM" "$service"
    copy_deployment_scripts "$DEST_USER" "$DEST_HOST" "$DEST_PORT" "$DEST_VM" "$service"
    
    # Execute actions on destination VM (deploy and start)
    echo -e "\nExecuting actions on Destination VM ($DEST_VM)..."
    local dest_success=true
    for action in 1 2; do
        echo -e "Executing step $action on Destination VM (${service^} service)"
        if ! execute_action $action "$DEST_USER" "$DEST_HOST" "$DEST_PORT" "$DEST_PATH" "$DEST_VM" "$service"; then
            echo "Sequence failed at step $action on Destination VM"
            dest_success=false
            break
        fi
    done
    
    # Only continue to source VM actions if destination was successful
    if $dest_success; then
        # 10-second pause between destination and source actions
        echo "Pausing for 10 seconds before proceeding to source VM actions..."
        sleep 10
        
        # Execute actions on source VM (stop and purge)
        echo -e "\nExecuting actions on Source VM ($SOURCE_VM)..."
        for action in 3 4; do
            echo -e "Executing step $action on Source VM (${service^} service)"
            if ! execute_action $action "$SOURCE_USER" "$SOURCE_HOST" "$SOURCE_PORT" "$SOURCE_PATH" "$SOURCE_VM" "$service"; then
                echo "Sequence failed at step $action on Source VM"
                dest_success=false
                break
            fi
        done
    fi
    
    # Close SSH connections
    close_ssh_connection "$SOURCE_USER" "$SOURCE_HOST" "$SOURCE_PORT" "$SOURCE_VM"
    close_ssh_connection "$DEST_USER" "$DEST_HOST" "$DEST_PORT" "$DEST_VM"
    
    if $dest_success; then
        echo -e "Job #$job_number completed successfully!\n"
        return 0
    else
        echo -e "Job #$job_number failed!\n"
        return 1
    fi
}

# Process multiple migration jobs in parallel
process_parallel_jobs() {
    local source_datacenter=$1
    local dest_datacenter=$2
    local source_vm_choices=$3
    local service=$4
    local source_vms=("${@:5}")
    local max_parallel_jobs=${MAX_PARALLEL_JOBS:-2}  # Default to 2 parallel jobs
    
    local active_jobs=0
    local job_pids=()
    local job_numbers=()
    
    for (( i=0; i<${#source_vm_choices}; i++ )); do
        local choice=${source_vm_choices:$i:1}
        local vm_index=$((choice-1))
        local job_number=$((i+1))
        
        echo -e "\n======================================================="
        echo "Starting migration job #$job_number: ${source_vms[$vm_index]}"
        echo "Service: ${service^}"
        echo "======================================================="
        
        # Run the job in background
        (process_migration_job "$job_number" "$source_datacenter" "$dest_datacenter" "$vm_index" "$service" "${source_vms[@]}") &
        local pid=$!
        job_pids+=($pid)
        job_numbers+=($job_number)
        active_jobs=$((active_jobs+1))
        
        # Wait if we've reached the maximum number of parallel jobs
        if [[ $active_jobs -ge $max_parallel_jobs ]]; then
            # Wait for any job to finish
            wait -n
            
            # Update active jobs count
            for (( j=0; j<${#job_pids[@]}; j++ )); do
                if ! kill -0 ${job_pids[$j]} 2>/dev/null; then
                    # Check if job was successful
                    wait ${job_pids[$j]}
                    local status=$?
                    
                    if [[ $status -ne 0 ]]; then
                        echo "Migration job #${job_numbers[$j]} failed!"
                        log "Migration job #${job_numbers[$j]} failed!"
                        
                        if [[ "$NON_INTERACTIVE" == "false" ]]; then
                            read -p "Continue with remaining jobs? (y/n): " continue_choice
                            if [[ $continue_choice != "y" && $continue_choice != "Y" ]]; then
                                log "Operation cancelled by user after job #${job_numbers[$j]} failure"
                                
                                # Kill all remaining jobs
                                for pid in "${job_pids[@]}"; do
                                    kill $pid 2>/dev/null
                                done
                                
                                return 1
                            fi
                        else
                            # In non-interactive mode, continue by default
                            log "Continuing with remaining jobs after failure (non-interactive mode)"
                        fi
                    fi
                    
                    # Remove this job from tracking arrays
                    unset job_pids[$j]
                    unset job_numbers[$j]
                    job_pids=("${job_pids[@]}")
                    job_numbers=("${job_numbers[@]}")
                    
                    active_jobs=$((active_jobs-1))
                    break
                fi
            done
        fi
    done
    
    # Wait for all remaining jobs to finish
    for (( j=0; j<${#job_pids[@]}; j++ )); do
        wait ${job_pids[$j]}
        local status=$?
        
        if [[ $status -ne 0 ]]; then
            echo "Migration job #${job_numbers[$j]} failed!"
            log "Migration job #${job_numbers[$j]} failed!"
        fi
    done
    
    return 0
}

# Validate datacenter name
validate_datacenter() {
    local dc_name=$1
    local valid=false
    
    for dc in "${DATACENTERS[@]}"; do
        if [[ "$dc" == "$dc_name" ]]; then
            valid=true
            break
        fi
    done
    
    if [[ "$valid" == "false" ]]; then
        return 1
    fi
    return 0
}

# Validate service name
validate_service() {
    local service_name=$1
    local valid=false
    
    for service in "${SERVICES[@]}"; do
        if [[ "$service" == "$service_name" ]]; then
            valid=true
            break
        fi
    done
    
    if [[ "$valid" == "false" ]]; then
        return 1
    fi
    return 0
}

# Convert comma-separated VM list to digit string
convert_vm_input() {
    local input=$1
    local max_vm=$2
    local vm_choices=""
    
    # Handle 'all' option
    if [[ "$input" == "all" ]]; then
        for (( i=1; i<=$max_vm; i++ )); do
            vm_choices="${vm_choices}${i}"
        done
        echo "$vm_choices"
        return 0
    fi
    
    # Convert comma-separated list to string of digits
    IFS=',' read -ra VM_ARRAY <<< "$input"
    for vm in "${VM_ARRAY[@]}"; do
        # Validate each VM number
        if [[ ! $vm =~ ^[1-9][0-9]*$ ]] || [[ $vm -gt $max_vm ]]; then
            echo "error"
            return 1
        fi
        vm_choices="${vm_choices}${vm}"
    done
    
    echo "$vm_choices"
}

# Main script execution
main() {
    # Clear log file at the start
    > "$ACTION_LOG"
    
    # Parse servers configuration and get datacenters
    parse_servers_config
    
    # Verify the required parameters for automated mode
    auto_mode_valid=true
    source_dc_index=-1
    dest_dc_index=-1
    source_vm_choices=""
    
    # Process SOURCE_DATACENTER
    if [[ -n "$SOURCE_DATACENTER" ]]; then
        if ! validate_datacenter "$SOURCE_DATACENTER"; then
            echo "ERROR: Invalid source datacenter: $SOURCE_DATACENTER"
            echo "Available datacenters:"
            for dc in "${DATACENTERS[@]}"; do
                echo "  $dc"
            done
            auto_mode_valid=false
        else
            # Find the index of the source datacenter
            for i in "${!DATACENTERS[@]}"; do
                if [[ "${DATACENTERS[$i]}" == "$SOURCE_DATACENTER" ]]; then
                    source_dc_index=$i
                    break
                fi
            done
        fi
    else
        auto_mode_valid=false
    fi
    
    # Process DEST_DATACENTER
    if [[ -n "$DEST_DATACENTER" ]]; then
        if ! validate_datacenter "$DEST_DATACENTER"; then
            echo "ERROR: Invalid destination datacenter: $DEST_DATACENTER"
            echo "Available datacenters:"
            for dc in "${DATACENTERS[@]}"; do
                echo "  $dc"
            done
            auto_mode_valid=false
        else
            # Check if source and destination are different
            if [[ "$SOURCE_DATACENTER" == "$DEST_DATACENTER" ]]; then
                echo "ERROR: Source and destination datacenters must be different"
                auto_mode_valid=false
            else
                # Find the index of the destination datacenter
                for i in "${!DATACENTERS[@]}"; do
                    if [[ "${DATACENTERS[$i]}" == "$DEST_DATACENTER" ]]; then
                        dest_dc_index=$i
                        break
                    fi
                done
            fi
        fi
    else
        auto_mode_valid=false
    fi
    
    # Get VMs for source datacenter if we have a valid source datacenter
    if [[ $source_dc_index -ge 0 ]]; then
        SOURCE_VMS=($(get_datacenter_vms "$SOURCE_DATACENTER"))
        
        # Process SOURCE_VM_INPUT if provided
        if [[ -n "$SOURCE_VM_INPUT" ]]; then
            # Convert input to digit string
            source_vm_choices=$(convert_vm_input "$SOURCE_VM_INPUT" "${#SOURCE_VMS[@]}")
            
            if [[ "$source_vm_choices" == "error" ]]; then
                echo "ERROR: Invalid VM numbers: $SOURCE_VM_INPUT"
                echo "Valid range is 1-${#SOURCE_VMS[@]} or 'all'"
                auto_mode_valid=false
            fi
        else
            auto_mode_valid=false
        fi
    fi
    
    # Process SELECTED_SERVICE
    if [[ -n "$SELECTED_SERVICE" ]]; then
        if ! validate_service "$SELECTED_SERVICE"; then
            echo "ERROR: Invalid service: $SELECTED_SERVICE"
            echo "Available services:"
            for svc in "${SERVICES[@]}"; do
                echo "  $svc"
            done
            auto_mode_valid=false
        fi
    else
        auto_mode_valid=false
    fi
    
    # Validate MAX_PARALLEL_JOBS
    if [[ -n "$MAX_PARALLEL_JOBS" ]]; then
        if [[ ! $MAX_PARALLEL_JOBS =~ ^[1-9][0-9]*$ ]]; then
            echo "ERROR: Invalid maximum parallel jobs: $MAX_PARALLEL_JOBS"
            echo "Must be a positive integer"
            MAX_PARALLEL_JOBS=2
            echo "Using default value: $MAX_PARALLEL_JOBS"
        fi
    else
        MAX_PARALLEL_JOBS=2
    fi
    
    # Interactive mode if not all parameters are valid or provided
    if [[ "$auto_mode_valid" == "false" ]]; then
        # Display datacenter options
        echo "Available Datacenters:"
        for i in "${!DATACENTERS[@]}"; do
            echo "$((i+1)). ${DATACENTERS[i]}"
        done

        # Select source datacenter if not valid from command line
        if [[ $source_dc_index -lt 0 ]]; then
            while true; do
                read -p "Select source datacenter (1-${#DATACENTERS[@]}): " source_dc_choice
                if [[ $source_dc_choice =~ ^[1-${#DATACENTERS[@]}]$ ]]; then
                    SOURCE_DATACENTER=${DATACENTERS[$((source_dc_choice-1))]}
                    break
                else
                    echo "Invalid choice. Please try again."
                fi
            done
        else
            echo "Using source datacenter: $SOURCE_DATACENTER"
        fi

        # Select destination datacenter if not valid from command line
        if [[ $dest_dc_index -lt 0 ]]; then
            while true; do
                read -p "Select destination datacenter (1-${#DATACENTERS[@]}): " dest_dc_choice
                if [[ $dest_dc_choice =~ ^[1-${#DATACENTERS[@]}]$ ]]; then
                    DEST_DATACENTER=${DATACENTERS[$((dest_dc_choice-1))]}
                    # Ensure destination is different from source
                    if [ "$DEST_DATACENTER" != "$SOURCE_DATACENTER" ]; then
                        break
                    else
                        echo "Destination datacenter must be different from source. Please try again."
                    fi
                else
                    echo "Invalid choice. Please try again."
                fi
            done
        else
            echo "Using destination datacenter: $DEST_DATACENTER"
        fi

        # Get VMs for source datacenter if needed
        if [[ -z "$SOURCE_VMS" ]]; then
            SOURCE_VMS=($(get_datacenter_vms "$SOURCE_DATACENTER"))
        fi

        # Display source VM options with "all" option
        echo "Available Source VMs:"
        for i in "${!SOURCE_VMS[@]}"; do
            echo "$((i+1)). ${SOURCE_VMS[i]}"
        done
        echo "$((${#SOURCE_VMS[@]}+1)). all"

        # Select source VMs if not valid from command line
        if [[ -z "$source_vm_choices" ]]; then
            while true; do
                read -p "Select source VMs (enter digits without spaces, e.g. 614 for VMs 6, 1, and 4, or select 'all'): " source_vm_input
                
                # Check if user selected "all"
                if [[ $source_vm_input =~ ^[aA][lL][lL]$ ]] || [[ $source_vm_input -eq $((${#SOURCE_VMS[@]}+1)) ]]; then
                    # Generate sequence for all VMs: "123456..." up to the number of VMs
                    source_vm_choices=""
                    for (( i=1; i<=${#SOURCE_VMS[@]}; i++ )); do
                        source_vm_choices="${source_vm_choices}${i}"
                    done
                    break
                fi
                
                # Validate input - only digits allowed
                if [[ ! $source_vm_input =~ ^[1-9]+$ ]]; then
                    echo "Invalid input. Please enter only digits corresponding to VM numbers."
                    continue
                fi
                
                # Validate that all digits are valid VM indices
                local invalid_choice=false
                for (( i=0; i<${#source_vm_input}; i++ )); do
                    local choice=${source_vm_input:$i:1}
                    if [[ $choice -gt ${#SOURCE_VMS[@]} ]]; then
                        echo "Invalid choice: $choice. Maximum is ${#SOURCE_VMS[@]}."
                        invalid_choice=true
                        break
                    fi
                done
                
                if [ "$invalid_choice" = true ]; then
                    continue
                fi
                
                source_vm_choices=$source_vm_input
                break
            done
        else
            echo "Using source VMs: $(echo $SOURCE_VM_INPUT | tr ',' ' ')"
        fi
        
        # Ask for parallel job count if not provided
        if [[ -z "$MAX_PARALLEL_JOBS" ]]; then
            read -p "Enter maximum number of parallel jobs [2]: " MAX_PARALLEL_JOBS
            MAX_PARALLEL_JOBS=${MAX_PARALLEL_JOBS:-2}  # Default to 2 if empty
            
            # Validate input for parallel jobs
            if [[ ! $MAX_PARALLEL_JOBS =~ ^[1-9][0-9]*$ ]]; then
                echo "Invalid input. Using default value of 2 parallel jobs."
                MAX_PARALLEL_JOBS=2
            fi
        else
            echo "Using maximum parallel jobs: $MAX_PARALLEL_JOBS"
        fi
        
        # Display service options if not provided
        if [[ -z "$SELECTED_SERVICE" ]]; then
            echo -e "\nAvailable Services:"
            for i in "${!SERVICES[@]}"; do
                echo "$((i+1)). ${SERVICES[i]}"
            done
            
            # Select service
            while true; do
                read -p "Select service (1-${#SERVICES[@]}): " service_choice
                if [[ $service_choice =~ ^[1-${#SERVICES[@]}]$ ]]; then
                    SELECTED_SERVICE=${SERVICES[$((service_choice-1))]}
                    break
                else
                    echo "Invalid choice. Please try again."
                fi
            done
        else
            echo "Using service: $SELECTED_SERVICE"
        fi
    fi

    # Show configuration summary and get final approval
    echo -e "\nConfiguration Summary:"
    echo -n "Source: $SOURCE_DATACENTER - Server Order: ("
    for (( i=0; i<${#source_vm_choices}; i++ )); do
        local choice=${source_vm_choices:$i:1}
        local vm_index=$((choice-1))
        echo -n "$((i+1))- ${SOURCE_VMS[$vm_index]} "
    done
    echo ")"
    
    echo -n "Destination: $DEST_DATACENTER - Server Order: ("
    for (( i=0; i<${#source_vm_choices}; i++ )); do
        local choice=${source_vm_choices:$i:1}
        local vm_index=$((choice-1))
        
        # Extract VM number from source VM name
        local source_vm_number=$(echo "${SOURCE_VMS[$vm_index]}" | sed "s/.*\([0-9]\+\).*/\1/")
        local dest_vm="cr${source_vm_number}${DEST_DATACENTER}"
        
        echo -n "$((i+1))- ${dest_vm} "
    done
    echo ")"
    
    echo "Maximum parallel jobs: $MAX_PARALLEL_JOBS"
    echo "Selected service: ${SELECTED_SERVICE^}"
    
    # Get confirmation in interactive mode
    if [[ "$NON_INTERACTIVE" == "false" ]]; then
        read -p "Continue? (y/n): " confirm
        if [[ $confirm != "y" && $confirm != "Y" ]]; then
            log "Operation cancelled by user"
            exit 0
        fi
    else
        echo "Running in non-interactive mode. Proceeding without confirmation..."
    fi

    # Process migration jobs in parallel
    process_parallel_jobs "$SOURCE_DATACENTER" "$DEST_DATACENTER" "$source_vm_choices" "$SELECTED_SERVICE" "${SOURCE_VMS[@]}"

    # Log completion
    log_header "All Service Transfer Operations Completed"
    
    echo -e "\nAll migration jobs completed!"
    echo "Action log: $ACTION_LOG"
}

# Run the main script
main