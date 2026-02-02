slurm_job_nodes_expanded()
{
    local jobid="$1"

    local nodelist
    nodelist=$(scontrol show job "$jobid" \
        | awk -F= '/NodeList=/{print $2}' \
        | awk '{print $1}')

    scontrol show hostnames "$nodelist"
}

slurm_base_jobid()
{
    echo "${1%%.*}"
}

