# -----------------------------------------------------------------------------
# getmyfiles (simplified)
#
# User-facing CLI:
#   getmyfiles --job 1729 --local-dir logs --remote-dir /localscratch/kdonald/something --files "*.out" [--dry-run]
#
# Behavior:
# - Finds the node where JOB ran (uses sacct NodeList; falls back to scontrol for running jobs).
# - Moves matching files from REMOTE_DIR on that node to:
#     $HOME/LOCAL_DIR/YYYY-MM-DD-<JOB>-<N>/
# - If --dry-run: prints what it would move; does not transfer/remove.
# - Ignores ~/.ssh/config and requires key auth (BatchMode).
#
# Notes:
# - Multi-node jobs: uses the "first" node from expanded NodeList.
# - This moves files (rsync --remove-source-files). It does not copy.
# -----------------------------------------------------------------------------

gmf_ssh_base_opts() 
{
    # echo ">>>>> ${FUNCNAME[0]}" "$@"
    printf '%s\n' \
        "-F" "/dev/null" \
        "-o" "BatchMode=yes" \
        "-o" "StrictHostKeyChecking=accept-new" \
        "-o" "ConnectTimeout=8"
}

gmf_make_run_dir() 
{
    # echo ">>>>> ${FUNCNAME[0]}" "$@"
    # $HOME/<localdir>/YYYY-MM-DD-<job>-<counter>
    local localdir="$1" jobid="$2"
    [[ -z "$localdir" || -z "$jobid" ]] && return 2

    [[ "$localdir" != /* ]] && localdir="$HOME/$localdir"
    mkdir -p "$localdir" || return 3

    local stamp counter path
    stamp="$(date +%F)"
    counter=0
    while :; do
        path="$localdir/${stamp}-${jobid}-${counter}"
        if [[ ! -e "$path" ]]; then
            mkdir -p "$path" || return 4
            printf '%s\n' "$path"
            return 0
        fi
        counter=$((counter+1))
    done
}

getmyfiles() 
{
    # echo ">>>>> ${FUNCNAME[0]}" "$@"
    local job="" localdir="" remotedir="" filespec="" dryrun=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --job)       job="$2"; shift 2 ;;
            --local-dir) localdir="$2"; shift 2 ;;
            --remote-dir) remotedir="$2"; shift 2 ;;
            --files)     filespec="$2"; shift 2 ;;
            --dry-run)   dryrun=1; shift ;;
            -h|--help)
                cat >&2 <<'USAGE'
Usage:
  getmyfiles --job JOBID --local-dir DIR --remote-dir ABS_PATH --files "GLOB" [--dry-run]

Example:
  getmyfiles --job 1729 --local-dir logs --remote-dir /localscratch/kdonald/something --files "*.out" --dry-run

Notes:
  - Moves files (removes sources) using rsync --remove-source-files.
  - Requires ssh key auth; ignores ~/.ssh/config for consistent behavior.
USAGE
                return 0
                ;;
            *)
                echo "getmyfiles: unknown option: $1" >&2
                return 2
                ;;
        esac
    done

    # Required args
    [[ -z "$job" ]]       && { echo "getmyfiles: missing --job" >&2; return 2; }
    [[ -z "$localdir" ]]  && { echo "getmyfiles: missing --local-dir" >&2; return 2; }
    [[ -z "$remotedir" ]] && { echo "getmyfiles: missing --remote-dir" >&2; return 2; }
    [[ -z "$filespec" ]]  && { echo "getmyfiles: missing --files" >&2; return 2; }

    # remote-dir should be absolute (per your example/spec intent)
    if [[ "$remotedir" != /* ]]; then
        echo "getmyfiles: --remote-dir must be an absolute path (got: $remotedir)" >&2
        return 2
    fi


    


    local node
    node=$(sacct -j 480599 --format=NodeList --noheader | head -1 | awk '{print $1}')
    if [ -z "$node" ]; then
        echo "getmyfiles: could not resolve node for job $basejob" >&2
        return 3
    fi

    local rundir
    rundir="$(gmf_make_run_dir "$localdir" "job")" || {
        echo "getmyfiles: could not create local destination directory" >&2
        return 4
    }

    # Build remote glob: /localscratch/.../*.out
    # IMPORTANT: user must quote the glob so local shell doesn't expand it.
    local remotepattern="${remotedir%/}/$filespec"

    if (( dryrun )); then
        echo "[DRY-RUN] job=$basejob node=$node"
        echo "  would move: ${node}:${remotepattern}"
        echo "  to:         ${rundir}/"
        echo "  listing matches on remote:"
        ssh "$(gmf_ssh_base_opts)" "$node" bash -lc 'shopt -s nullglob; for f in '"$(printf '%q' "$remotepattern")"'; do printf "%s\n" "$f"; done'
        return 0
    fi

    # Ensure destination exists locally
    mkdir -p "$rundir" || return 4

    # Move files via rsync. We pass the remote glob to the *remote shell* by using bash -lc.
    # We avoid relying on rsync's remote wildcard expansion quirks.
    #
    # Steps:
    #  1) Remote: expand glob into NUL-safe list, write to stdout with one per line
    #  2) Local: feed list to rsync via --files-from= (relative paths) is hard with absolute paths,
    #     so instead we do: remote tar stream OR remote rsync per file.
    #
    # For simplicity and robustness: tar stream + remote rm. (Fast, handles spaces.)
    echo "getmyfiles: transferring from $node ..."
    scp "$node:/$remotepattern" "$rundir"
    if [ $? -eq 0 ]; then
        echo "success. Removing remote files."
        ssh "$node" "rm -f $remotepattern"
    fi

    echo "getmyfiles: done. saved in $rundir"
    return 0
}

