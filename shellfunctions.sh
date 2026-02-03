slurm_job_nodes_expanded()
{
    local jobid="$1"

    local nodelist
    nodelist=$(scontrol show job "$jobid" \
        | awk -F= '/NodeList=/{print $2}' \
        | awk '{print $1}')

    scontrol show hostnames "$nodelist"
}

gmf_ssh_base_opts()
{
    # -F /dev/null ignores ~/.ssh/config
    # BatchMode=yes prevents password prompts (fails fast if no key auth)
    # StrictHostKeyChecking=accept-new is friendlier than "no" but still safe-ish.
    # Adjust known_hosts path if you want to isolate it.
    printf '%s\n' "-F" "/dev/null" \
                  "-o" "BatchMode=yes" \
                  "-o" "StrictHostKeyChecking=accept-new" \
                  "-o" "ConnectTimeout=8"
}

gmf_slurm_base_jobid()
{
    local jobid="$1"
    [[ -z "$jobid" ]] && return 2
    printf '%s\n' "${jobid%%.*}"
}

gmf_slurm_job_nodes()
{
    local jobid; jobid="$(gmf_slurm_base_jobid "$1")" || return 2

    # Get compressed NodeList=... then expand to hostnames
    local nodelist
    nodelist=$(scontrol show job "$jobid" 2>/dev/null \
        | awk -F= '/\bNodeList=/{print $2}' \
        | awk '{print $1}' \
        | head -n1)

    [[ -z "$nodelist" ]] && return 3
    scontrol show hostnames "$nodelist"
}

gmf_slurm_my_most_recent_job()
{
    # Prefer jobs that actually ended (completed/failed/etc.), not job steps.
    sacct -u "$USER" --starttime now-7days \
        --format=JobIDRaw,End,State --noheader \
        | awk '
            $1 ~ /^[0-9]+$/ && $2 != "Unknown" {print $0}
          ' \
        | sort -k2,2 \
        | tail -n1 \
        | awk '{print $1}'
}

gmf_resolve_hosts()
{
    local host_arg="$1" job_arg="$2"

    if [[ -n "$host_arg" ]]; then
        printf '%s\n' "$host_arg"
        return 0
    fi

    if [[ -z "$job_arg" && -n "$SLURM_JOB_ID" ]]; then
        job_arg="$SLURM_JOB_ID"
    fi

    if [[ -z "$job_arg" ]]; then
        job_arg="$(gmf_slurm_my_most_recent_job)" || true
    fi

    [[ -z "$job_arg" ]] && return 4
    gmf_slurm_job_nodes "$job_arg"
}

gmf_make_dest_dir()
{
    local dest="$1" jobid="$2"

    [[ -z "$dest" ]] && return 2
    [[ "$dest" != /* ]] && dest="$HOME/$dest"

    mkdir -p "$dest" || return 3

    local stamp counter path suffix=""
    stamp="$(date +%F)"   # 2026-02-03
    [[ -n "$jobid" ]] && suffix="-$(gmf_slurm_base_jobid "$jobid")"

    counter=0
    while :; do
        path="$dest/${stamp}${suffix}-${counter}"
        if [[ ! -e "$path" ]]; then
            mkdir -p "$path" || return 4
            printf '%s\n' "$path"
            return 0
        fi
        counter=$((counter+1))
    done
}

gmf_host_is_clusterish()
{
    local h="$1"
    # Accept IPv4 RFC1918-ish and nodeNN style hostnames
    [[ "$h" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0
    [[ "$h" =~ ^[a-zA-Z]*node[0-9]{2,3}(\..*)?$ ]] && return 0
    return 1
}


gmf_remote_home()
{
    local host="$1"
    ssh "$(gmf_ssh_base_opts)" "$host" 'printf "%s\n" "$HOME"' 2>/dev/null
}

gmf_remote_glob_list0()
{
    local host="$1" remote_home="$2" filespec="$3"
    [[ -z "$host" || -z "$remote_home" || -z "$filespec" ]] && return 2

    # We avoid eval. We let the remote shell expand the glob by placing it
    # unquoted in a controlled context.
    # NOTE: This assumes filespec is intended as a shell glob, not regex.
    ssh "$(gmf_ssh_base_opts)" "$host" bash -lc '
        set -o noglob
        remote_home="$1"
        spec="$2"
        set +o noglob

        shopt -s nullglob dotglob globstar 2>/dev/null || true
        # Expand relative to remote_home
        cd "$remote_home" || exit 10
        matches=( $spec )
        ((${#matches[@]}==0)) && exit 0
        printf "%s\0" "${matches[@]}"
    ' -- "$remote_home" "$filespec"
}

gmf_tar_stream_unpack()
{
    local host="$1" remote_home="$2" destdir="$3"
    shift 3
    local paths=("$@")
    [[ ${#paths[@]} -eq 0 ]] && return 0

    # Create archive remotely from inside remote_home, extract locally into destdir
    ssh "$(gmf_ssh_base_opts)" "$host" bash -lc '
        remote_home="$1"; shift
        cd "$remote_home" || exit 11
        tar -czf - -- "$@"
    ' -- "$remote_home" "${paths[@]}" \
    | tar -xzf - -C "$destdir"
}

gmf_remote_remove()
{
    local host="$1" remote_home="$2"
    shift 2
    local paths=("$@")
    [[ ${#paths[@]} -eq 0 ]] && return 0

    ssh "$(gmf_ssh_base_opts)" "$host" bash -lc '
        remote_home="$1"; shift
        cd "$remote_home" || exit 12
        rm -rf -- "$@"
    ' -- "$remote_home" "${paths[@]}"
}

gmf_require_single_host_unless_justdoit()
{
    local justdoit="$1"; shift
    local hosts=("$@")

    if [[ ${#hosts[@]} -eq 0 ]]; then
        echo "getmyfiles: could not resolve any source host(s)" >&2
        return 4
    fi

    if [[ ${#hosts[@]} -gt 1 && "$justdoit" != "1" ]]; then
        echo "getmyfiles: job spans multiple nodes:" >&2
        printf '  %s\n' "${hosts[@]}" >&2
        echo "Re-run with --just-do-it to retrieve from all nodes." >&2
        return 6
    fi

    return 0
}

gmf_host_subdir()
{
    local dest_run="$1" host="$2"
    [[ -z "$dest_run" || -z "$host" ]] && return 2
    mkdir -p "$dest_run/$host" || return 3
    printf '%s\n' "$dest_run/$host"
}

gmf_add_filespec()
{
    local -n _arr_ref="$1"
    local spec="$2"
    [[ -z "$spec" ]] && return 2
    _arr_ref+=("$spec")
}

gmf_print_plan()
{
    local mode="$1" host="$2" dest="$3" remote_home="$4" spec="$5"
    printf '[%s] host=%s  remote=%s/%s  ->  %s\n' \
        "$mode" "$host" "$remote_home" "$spec" "$dest"
}

make_junk_files()
{
    # Create N files of size SIZE bytes with random ASCII content.
    #
    # Usage:
    #   make_junk_files PREFIX COUNT SIZE [SUFFIX]
    #
    # Examples:
    #   make_junk_files junk 5 1048576 .chk
    #   make_junk_files log 10 4096 .log
    #
    # Result:
    #   junk001.chk junk002.chk ... junk005.chk

    local prefix="$1"
    local count="$2"
    local size="$3"
    local suffix="${4:-.chk}"

    if [[ -z "$prefix" || -z "$count" || -z "$size" ]]; then
        echo "usage: make_junk_files PREFIX COUNT SIZE [SUFFIX]" >&2
        return 2
    fi

    if ! [[ "$count" =~ ^[0-9]+$ && "$size" =~ ^[0-9]+$ ]]; then
        echo "count and size must be integers (bytes)." >&2
        return 3
    fi

    local i fname
    for ((i=1; i<=count; i++)); do
        printf -v fname "%s%03d%s" "$prefix" "$i" "$suffix"

        # Generate printable ASCII (space through ~)
        head -c "$size" /dev/urandom \
            | tr -dc ' -~' \
            | head -c "$size" \
            > "$fname"

        printf 'created %s (%d bytes)\n' "$fname" "$size"
    done
}

make_junk_files_safe()
{
    local prefix="$1"
    local count="$2"
    local size="$3"
    local suffix="${4:-.chk}"

    local max_total=$((500 * 1024 * 1024))   # 500 MB safety cap
    local total=$((count * size))

    if (( total > max_total )); then
        echo "Refusing: would create $total bytes (> $max_total cap)" >&2
        echo "Edit function if you really mean it." >&2
        return 9
    fi

    make_junk_files "$@"
}

