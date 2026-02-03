#!/bin/bash -e

#SBATCH --job-name=catnap
#SBATCH --output=catnap.%j.out
#SBATCH --ntasks=1
#SBATCH --mail-type=ALL

#SBATCH --partition=cpunodes
#SBATCH --cpus-per-task=1
#SBATCH --time=00:10:00
#SBATCH --mem=2G

# Print start time
echo "Job started on: $(date)"
echo "SLURM Job ID: $SLURM_JOB_ID"
echo "SLURM Partition: $SLURM_JOB_PARTITION"
echo "SLURM Node List: $(scontrol show hostname $SLURM_NODELIST)"
echo "SLURM CPUs per task: $SLURM_CPUS_PER_TASK"

# Change to job submission directory
cd "$SLURM_SUBMIT_DIR"

# Make the dir on /localscratch for our junk files
export SCRATCH=/localscratch/catnap
mkdir -p "$SCRATCH"
cd "$SCRATCH"


make_junk_files()
{
    ####
    # Usage:
    #   make_junk_files PREFIX COUNT SIZE [SUFFIX]
    #
    # Create N files of size SIZE bytes with random ASCII content.
    ####

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

# make some files ...
make_junk_files catnap 5 123456 .out

# hang around long enough that we can see the job with squeue
/usr/bin/time -v /usr/bin/sleep 120

# Print end time
echo "Job finished on: $(date)"

