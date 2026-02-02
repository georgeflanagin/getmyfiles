# getmyfiles
Shell function to retrieve files from a cluster's nodes to $HOME

This tool allows the user to retrieve files and move them to the user's home 
directory. While it will work in any environment that uses IP addressing, the 
intent is to use it primarily with clusters.

There are a couple of assumptions that users must keep in mind.

- Runs entirely as the invoking user; normal filesystem permissions apply (no privilege escalation), no sudo-ing.
- It does not copy the files, it moves them from the place where they are now to the directory you specify, and removes the files from wherever they are now.
- As a user, you must have ssh-key authentication to avoid constantly being asked for your password.
- While you *could* move files within the same local file system, that's a pointless activity. `mv` and `cp` work well enough.
- The common Linux tools -- `rsync`, `tar`, `gzip`, *etc* -- must be present in your environment. They almost always are.
- This tool ignores in the information in `$HOME/.ssh/config` to ensure consistent behavior. We have no way of knowing what is in your ssh config file, and you might have defined `node42` to mean something else.

## command line use

The general syntax is the customary Linux tool standard. The options can be present in any order.

```bash
getmyfiles [opts] 
```

## Options

- `--dest` : If the destination directory is just a bare name like "logs", it is assumed to be under `$HOME`. For example if you specify `logs`, you mean `$HOME/logs`. If the directory does not exist, it will be created. You can name any directory you like, and you will need write access to it.
- `--dry-run` : Just show what files would have been affected rather than moving any files.
- `--files` : This filespec is applied to the files in the remote location, and if it does not match anything (because of a typo, there is nothing there, etc.) you do not retrieve files. Like the destination, this spec is applied starting at $HOME in the remote location. The filespec must be quoted if it contains a "*", "?", or anything else that might be a wildcard, and it usually does. This option can be repeated to get multiple groups of files in one sweep.
- `--host` : the value can be an IP address or a hostname, with the assumption that the remote user name is the same as the user currently running the program.
- `--job` : only works in SLURM environments. This uses the value to look up the node where the job ran.
- `--just-do-it` : accept all defaults stored in `$HOME/.local/getmyfiles.config`
- `--unpack` : If present, the directory structure from the remote location is "cloned" into the destination. If not, the directory will contain a gzipped tarball whose fate you can decide. The reason for this option is that it is a lot easier to download one tarball to your PC than it is to download a directory full of files.

## Things to keep in mind

- Each operation will create a directory under `--dest` that is date stamped. This prevents collisions and makes it easier to find "those files from last Friday."
- Files are only removed *after* the transfer has been successful. If something goes wrong with the transfer, you can rerun it and pick up where you left off.

## Explanatory examples

[1] Get my `log` files from node42, and put them in `$HOME/logfiles`

```bash
getmyfiles --host node42 --dest logfiles --files "*.log" --unpack
```

The result will be a directory named `$HOME/logfiles/2026-02-02-0` that contains `x.log`, `y.log`, and so on. The `-0` suffix allows for multiple collections of similar files on the same day. 

[2] Get my checkpoint files and my log files from job 1729, put them a directory named junk, and just leave it as a tarball.

```bash
getmyfiles --job 1729 --dest junk --files "*.log" --files "*.chk"
```

The result will be a directory named `$HOME/junk/2026-02-02-1729` that contains a file named `files.tgz`. Note that the job id is used as the serialization for the name.
