#!/bin/bash

##---- USER VARIABLES
. $(dirname $0)/protect_in_vault.cfg

##---- SCRIPT VARIABLES
D2D_DIR_NAME="d2d"
VAULT_DIR_NAME="vault"
BACKUP_TIME="$(date +'%Y%m%d-%H%M')"
LOG_FILE=/tmp/dW5pcXVlaWRmb3J2YXVsdGJhY2t1cC0t-vaultbackup.log
((RETENTION_COUNT++))					# need to add 1 to variable to be inline with tail

##---- FUNCTIONS
error_exist_in_log() {
	[[ $(grep -ci 'ERROR' $LOG_FILE) -ne 0 ]]
}

log() {
	function _add_to_log() {
		if [[ $# -eq 0 ]]; then
			return
		fi

		if [[ $SHOW_LOG_IN_CONSOLE -eq 1 ]]; then
			echo $(date) " -- " $* | tee -a $LOG_FILE
		else
			echo $(date) " -- " $* >> $LOG_FILE
		fi
	}
	
	local t
	
	if [[ $# -eq 0 ]]; then # function has been piped
		while read t; do
			_add_to_log $t
		done
    else	
        _add_to_log $*
    fi
}

echo_err() {
	echo "Error: " $* >&2
}

save_pipe_status() {
	_saved_pipe_status=( "${PIPESTATUS[@]}" )
}

generate_mail_body() {
	echo "-------------- LOG --------------"
	cat $LOG_FILE
}

send_mail() {
	echo "$2" | mutt -e "my_hdr Content-Type: text/html" -s "$1" -- ${MAIL_TO}
}

#1: (optional) index of command to check exit status. If ommited, all command exit status are tested
is_error_in_last_cmd() {	
	local e
	
	if [[ $# -ne 0 ]]; then 					# if any arguments passed
		if [[ $1 -lt ${#_saved_pipe_status[@]} ]]; then	# if index inside array boundaries
			[[ ${_saved_pipe_status[$1]} -ne 0 ]]
		else
			false 								# if index greater than array boundaries, return false
		fi
		return
	fi
	
	# if no arguments passed, check all exit codes
	for e in "${_saved_pipe_status[@]}"; do
		[[ ! $e -eq 0 ]] && return 0
	done
	return 1
}

is_dir_empty() {
	! find "$1" -mindepth 1 -print -quit | grep -q .
}

#1: path to proceed
save_to_vault() {
	local d2d_path="$ROOT_BACKUP_DIR/$D2D_DIR_NAME/$1"
	local vault_path="$ROOT_BACKUP_DIR/$VAULT_DIR_NAME/$1"
	# local matching_pattern='\d{8}-\d{4}--(.+)\.gz'
	local match_var=.+?
	local matching_pattern="(?<=\d{8}-\d{4}--)${match_var}(?=(\.tar)?\.gz)"
	
	echo "saving $d2d_path"
	echo "to $vault_path"
	
	local item_with_count
	# get each item to save in vault with count	
	ls -1 "$d2d_path" | grep -Po "$matching_pattern" | sort | uniq -c | 
		while read item_with_count; do
			echo "Processing $item_with_count"
			
			# split count and item name
#			local item_count=$(echo "$item_with_count" | cut -c-7 | tr -d '[:space:]')
			local item_count=$(grep -Po '^\d+' <<< "$item_with_count")
#			local item_name=$(echo "$item_with_count" | cut -c9-)
			local item_name=$(grep -Po '[^ ]*$' <<< "$item_with_count")
			
			# check if count is not reaching nor exceeding the thresholds
			if [[ $item_count -eq $NEW_FILE_WARNING_THRESHOLD ]]; then
				echo_err "NEW_FILE_WARNING_THRESHOLD : Lot of {${item_name}} were added"
			elif [[ $item_count -ge $NEW_FILE_STOP_THRESHOLD ]]; then
				echo_err "NEW_FILE_STOP_THRESHOLD : Lot of {${item_name}} were added. Stop processing!"
				continue;
			fi
			
			# processing this item
			match_var=$item_name
			local file
			ls -1 "$d2d_path" | grep -P "$matching_pattern" |
				while read file; do
					# check if file is not corrupted
					if ! gzip -t "$d2d_path/$file"; then
						echo_err "file corrupted: $d2d_path/$file"
						rm -f "$d2d_path/$file"
						continue
					fi
					
					# move it to vault (ensure path exists)
					echo "Moving $d2d_path/$file to $vault_path/$item_name/$file"
					mkdir -p "$vault_path/$item_name"
					mv "$d2d_path/$file" "$vault_path/$item_name/$file"
					[[ $? -ne 0 ]] && echo_err "Cannot move this file to vault"
				done
		done
}

#1: path to proceed
housekeeping() {
	local vault_path="$ROOT_BACKUP_DIR/$VAULT_DIR_NAME/$1"
	
	echo "housekeeping on $vault_path"
	
	# delete old backups
	local dir	
	ls -d1 $vault_path/*/ | 
		while read dir; do
			local file_to_delete
			dir=${dir%/} # remove trailing slash
			ls -1r "$dir" | tail -n+$RETENTION_COUNT |
				while read file_to_delete; do
					dir_empty=0
					echo "removing old backup: $dir/$file_to_delete"
					rm -f "$dir/$file_to_delete"
					[[ $? -ne 0 ]] && echo_err "Cannot delete this backup file"
				done
			if is_dir_empty "$dir"; then
				echo "Removing empty directory $dir"
				rmdir "$dir"
				[[ $? -ne 0 ]] && echo_err "Cannot remove directory"
			fi
		done
}

main() {
	# reset or create log file
	: > $LOG_FILE
	
#	echo $RETENTION_COUNT
	
	for dir in ${BACKUP_DIRS[@]}; do		
		save_to_vault "$dir"
		housekeeping "$dir"
	done |& log
	
	if error_exist_in_log; then
		# if errors => send email
		log "Error in log => sending email"
		send_mail "hetzner-predict-dev -- PROTECT BACKUP ERROR" "$(generate_mail_body)"
	else
		# do not delete log if any errors
		rm $LOG_FILE
	fi
}

main
