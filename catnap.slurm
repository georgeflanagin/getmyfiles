#!/bin/bash -e

#SBATCH --job-name=catnap
#SBATCH --output=catnap.%j.out
#SBATCH --ntasks=1
#SBATCH --mail-type=ALL

#SBATCH --partition=cpunodes
#SBATCH --cpus-per-task=1
#SBATCH --time=00:10:00
#SBATCH --mem=1G

# Print start time
echo "Job started on: $(date)"
echo "SLURM Job ID: $SLURM_JOB_ID"
echo "SLURM Partition: $SLURM_JOB_PARTITION"
echo "SLURM Node List: $(scontrol show hostname $SLURM_NODELIST)"
echo "SLURM CPUs per task: $SLURM_CPUS_PER_TASK"

# Change to job submission directory
cd "$SLURM_SUBMIT_DIR"

# Run test workload
/usr/bin/time -v /usr/bin/sleep 60

# Print end time
echo "Job finished on: $(date)"

