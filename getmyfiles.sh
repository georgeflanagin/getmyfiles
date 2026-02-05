# -----------------------------------------------------------------------------
# getmyfiles + helpers
#
# Source this file (or paste into your bashrc.d/cluster toolkit) to define:
#   - getmyfiles            (main tool per your spec)
#   - gmf_* helper funcs    (reusable)
#
# Notes:
# - Ignores ~/.ssh/config via: ssh -F /dev/null
# - Requires ssh key auth (BatchMode=yes, fails fast if not)
# - Remote base directory for --files is $REMOTE_HOME (remote user's $HOME)
# - --job wins over --host
# - Multi-node jobs: first node only unless --just-do-it
# - --just-do-it supersedes --dry-run
# -----------------------------------------------------------------------------

# ---- helpers ---------------------------------------------------------------

gmf_die() 
{
    local rc="${1:-1}"; shift
    echo "getmyfiles: $*" >&2
    return "$rc"
}

gmf_usage() 
{
    cat >&2 <<'USAGE'
Usage:
  getmyfiles [opts]

Options:
  --dest DIR        Destination base directory. If bare name, it's under $HOME.
                    A dated run directory is created under --dest.
  --files GLOB      Remote filespec (shell glob) relative to remote $HOME.
                    Repeatable. Quote globs, e.g. --files "*.log"
                    If a glob matches a directory, it is included recursively.
  --host HOST       Remote host (or user@host). Ignored if --job is provided.
  --job JOBID       Slurm job id (accepts 1729, 1729.batch, 1729.0, etc.).
                    Resolves node(s) where the job ran; --job wins over --host.
  --unpack          Extract files into destination (clone structure).
                    Otherwise create tarball files.tgz in destination run dir.
  --dry-run         Show what would happen, do not transfer/remove.
  --just-do-it      Automation/expert mode; supersedes --dry-run.
                    Also: multi-node jobs retrieve from all nodes into subdirs.
  -h|--help         Show help.

Constraints:
  - Runs as invoking user (no sudo); normal permissions apply.
  - Moves files: removes sources only after successful transfer.
USAGE
}

gmf_ssh_base_opts() 
{
    # Ignores ~/.ssh/config and avoids password prompts.
    # Adjust StrictHostKeyChecking policy if you prefer different behavior.
    printf '%s\n' \
        "-F" "/dev/null" \
        "-o" "BatchMode=yes" \
        "-o" "StrictHostKeyChecking=accept-new" \
        "-o" "ConnectTimeout=8"
}

gmf_slurm_base_jobid() 
{
    ###
    # Strip the output of a slurm command to just a bare number.
    ###
    local jobid="$1"
    [[ -z "$jobid" ]] && return 2
    printf '%s\n' "${jobid%%.*}"
}

gmf_slurm_job_nodes() 
{
    ###
    # For simplicity, let's assume this all ran on one node.
    ###
    local jobid; jobid="$(gmf_slurm_base_jobid "$1")" || return 2

    local nodelist
    nodelist=$(sacct -j "$jobid" --format=NodeList) | tail -n +3 | head -1

    [[ -z "$nodelist" ]] && return 3

    scontrol show hostnames "$nodelist"
}

gmf_slurm_my_most_recent_job() 
{
    # Most recent job with a known End time. (Not steps; base IDs only.)
    sacct -u "$USER" --starttime now-7days \
        --format=JobIDRaw,End,State --noheader 2>/dev/null \
    | awk '$1 ~ /^[0-9]+$/ && $2 != "Unknown" {print $0}' \
    | sort -k2,2 \
    | tail -n1 \
    | awk '{print $1}'
}

gmf_resolve_hosts() 
{
    # host_arg may be empty; job_arg may be empty.
    local host_arg="$1" job_arg="$2"

    if [[ -n "$job_arg" ]]; then
        gmf_slurm_job_nodes "$job_arg"
        return $?
    fi

    if [[ -n "$host_arg" ]]; then
        printf '%s\n' "$host_arg"
        return 0
    fi

    # No --job, no --host: assume Slurm environment; pick best job.
    if [[ -n "$SLURM_JOB_ID" ]]; then
        job_arg="$SLURM_JOB_ID"
    else
        job_arg="$(gmf_slurm_my_most_recent_job)" || true
    fi
    [[ -z "$job_arg" ]] && return 4

    gmf_slurm_job_nodes "$job_arg"
}

gmf_remote_home() 
{
    # Remote home directory for the provided host (or user@host)
    local host="$1"
    ssh "$(gmf_ssh_base_opts)" "$host" 'printf "%s\n" "$HOME"' 2>/dev/null
}

gmf_make_dest_dir() 
{
    # Create dated run directory under dest base, optionally suffixed with -JOBID.
    # Also adds -0, -1, ... to avoid collisions.
    local dest="$1" jobid="$2"
    [[ -z "$dest" ]] && return 2

    [[ "$dest" != /* ]] && dest="$HOME/$dest"
    mkdir -p "$dest" || return 3

    local stamp suffix="" counter path
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

gmf_host_subdir() 
{
    local dest_run="$1" host="$2"
    [[ -z "$dest_run" || -z "$host" ]] && return 2
    mkdir -p "$dest_run/$host" || return 3
    printf '%s\n' "$dest_run/$host"
}

gmf_remote_glob_list0() 
{
    # Print NUL-delimited list of matches for filespec relative to remote_home.
    # Safe with spaces/newlines in filenames.
    local host="$1" remote_home="$2" filespec="$3"
    [[ -z "$host" || -z "$remote_home" || -z "$filespec" ]] && return 2

    ssh "$(gmf_ssh_base_opts)" "$host" bash -lc '
        remote_home="$1"
        spec="$2"

        cd "$remote_home" || exit 10

        # Make globs nicer:
        shopt -s nullglob dotglob globstar 2>/dev/null || true

        # Expand spec relative to remote_home
        matches=( $spec )
        ((${#matches[@]}==0)) && exit 0

        printf "%s\0" "${matches[@]}"
    ' -- "$remote_home" "$filespec"
}

gmf_tar_stream_to_file() 
{
    # Create local tar.gz file from remote paths (relative to remote_home).
    local host="$1" remote_home="$2" outfile="$3"
    shift 3
    local paths=("$@")
    [[ ${#paths[@]} -eq 0 ]] && return 0

    ssh "$(gmf_ssh_base_opts)" "$host" bash -lc '
        remote_home="$1"; shift
        cd "$remote_home" || exit 11
        tar -czf - -- "$@"
    ' -- "$remote_home" "${paths[@]}" > "$outfile"
}

gmf_tar_stream_unpack() 
{
    # Extract remote tar.gz stream into local destdir.
    local host="$1" remote_home="$2" destdir="$3"
    shift 3
    local paths=("$@")
    [[ ${#paths[@]} -eq 0 ]] && return 0

    ssh "$(gmf_ssh_base_opts)" "$host" bash -lc '
        remote_home="$1"; shift
        cd "$remote_home" || exit 11
        tar -czf - -- "$@"
    ' -- "$remote_home" "${paths[@]}" \
    | tar -xzf - -C "$destdir"
}

gmf_remote_remove() 
{
    # Remove remote paths (relative to remote_home) after successful transfer.
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

gmf_first_hostname() 
{
    # "First node" defined as first hostname returned by scontrol show hostnames
    local line
    IFS= read -r line || return 1
    printf '%s\n' "$line"
    # drain stdin (so callers can still use command substitution safely)
    cat >/dev/null
}

# ---- main tool ------------------------------------------------------------

getmyfiles() 
{
    local dest="" host="" job="" unpack=0 dryrun=0 justdoit=0
    local -a filespecs=()

    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dest)
                dest="$2"; shift 2 ;;
            --host)
                host="$2"; shift 2 ;;
            --job)
                job="$2"; shift 2 ;;
            --files)
                filespecs+=("$2"); shift 2 ;;
            --unpack)
                unpack=1; shift ;;
            --dry-run)
                dryrun=1; shift ;;
            --just-do-it)
                justdoit=1; shift ;;
            -h|--help)
                gmf_usage; return 0 ;;
            *)
                gmf_usage
                return "$(gmf_die 1 "unknown option: $1")" ;;
        esac
    done

    # Spec: --just-do-it supersedes --dry-run
    if [[ "$justdoit" == "1" ]]; then
        dryrun=0
    fi

    # Require at least one --files
    if [[ ${#filespecs[@]} -eq 0 ]]; then
        gmf_usage
        return "$(gmf_die 1 "at least one --files pattern is required")"
    fi

    # Default destination if not provided: a predictable home subdir
    if [[ -z "$dest" ]]; then
        dest="getmyfiles"
    fi

    # Resolve host(s). Spec: --job wins against --host.
    local -a hosts=()
    local resolved
    if [[ -n "$job" ]]; then
        resolved="$(gmf_resolve_hosts "" "$job")" || return "$(gmf_die 2 "unable to resolve host(s) for --job $job")"
    else
        resolved="$(gmf_resolve_hosts "$host" "")" || return "$(gmf_die 2 "unable to resolve host(s) (need --host or Slurm job context)")"
    fi

    # Populate hosts array
    while IFS= read -r line; do
        [[ -n "$line" ]] && hosts+=("$line")
    done <<< "$resolved"

    if [[ ${#hosts[@]} -eq 0 ]]; then
        return "$(gmf_die 2 "no host(s) resolved")"
    fi

    # Multi-node policy:
    # - default: first node only
    # - with --just-do-it: all nodes
    if [[ ${#hosts[@]} -gt 1 && "$justdoit" != "1" ]]; then
        hosts=("${hosts[0]}")
    fi

    # If --job and multi-node + justdoit, we'll create per-host subdirs.
    # Create base run directory (date-stamped) under dest.
    local base_run
    base_run="$(gmf_make_dest_dir "$dest" "$job")" || return "$(gmf_die 3 "could not create destination run directory")"

    # If tarball mode, single tarball per host to avoid collisions
    local tarname="files.tgz"

    # Work each host
    local h remote_home host_run
    for h in "${hosts[@]}"; do
        # Decide per-host destination directory
        if [[ ${#hosts[@]} -gt 1 ]]; then
            host_run="$(gmf_host_subdir "$base_run" "$h")" || return "$(gmf_die 3 "could not create host subdir for $h")"
        else
            host_run="$base_run"
        fi

        echo "checking for home dir on $h"
        remote_home="$(gmf_remote_home "$h")"
        [[ -z "$remote_home" ]] && return "$(gmf_die 2 "could not determine remote home on $h (ssh failure?)")"

        # Collect matches across all --files patterns
        local -a all_matches=()
        local spec
        for spec in "${filespecs[@]}"; do
            # Fetch NUL-delimited list and read into array
            local -a matches=()
            local out
            out="$(gmf_remote_glob_list0 "$h" "$remote_home" "$spec")" || return "$(gmf_die 2 "remote glob failed on $h for spec: $spec")"

            # Read NUL-separated output
            while IFS= read -r -d '' m; do
                matches+=("$m")
            done <<< "$out"

            if [[ ${#matches[@]} -eq 0 ]]; then
                echo "getmyfiles: warning: on $h, --files '$spec' matched nothing under $remote_home" >&2
                continue
            fi

            # Append
            all_matches+=("${matches[@]}")
        done

        if [[ ${#all_matches[@]} -eq 0 ]]; then
            echo "getmyfiles: warning: on $h, no files matched any --files pattern; nothing to do." >&2
            continue
        fi

        # Dry run: show plan
        if [[ "$dryrun" == "1" ]]; then
            echo "[DRY-RUN] host=$h remote_home=$remote_home -> $host_run"
            printf '  would move: %s\n' "${all_matches[@]}"
            continue
        fi

        # Transfer
        if [[ "$unpack" == "1" ]]; then
            # Unpack into host_run
            gmf_tar_stream_unpack "$h" "$remote_home" "$host_run" "${all_matches[@]}" \
                || return "$(gmf_die 4 "transfer/unpack failed from $h")"

            # Remove sources after success
            gmf_remote_remove "$h" "$remote_home" "${all_matches[@]}" \
                || return "$(gmf_die 5 "remote remove failed on $h (files may have been transferred but not removed)")"

        else
            # Tarball mode: create files.tgz under host_run
            local outfile="$host_run/$tarname"
            gmf_tar_stream_to_file "$h" "$remote_home" "$outfile" "${all_matches[@]}" \
                || return "$(gmf_die 4 "transfer/tarball creation failed from $h")"

            gmf_remote_remove "$h" "$remote_home" "${all_matches[@]}" \
                || return "$(gmf_die 5 "remote remove failed on $h (tarball exists but remote cleanup failed)")"
        fi
    done

    return 0
}

