// Conservative generic indicators for Linux post-exploitation tooling.
// Deliberately narrow: these strings barely occur in legitimate software,
// keeping the false-positive rate near zero for a monitor-first rollout.

rule Linux_Reverse_Shell_OneLiner
{
    meta:
        description = "Classic /dev/tcp reverse shell one-liner in a file"
    strings:
        $a = "bash -i >& /dev/tcp/" ascii
        $b = "sh -i >& /dev/tcp/" ascii
        $c = "0<&196;exec 196<>/dev/tcp/" ascii
    condition:
        any of them
}

rule Linux_LD_PRELOAD_Rootkit_Markers
{
    meta:
        description = "Strings characteristic of LD_PRELOAD userland rootkits"
    strings:
        $a = "unhide.rb" ascii
        $b = "ld.so.preload" ascii
        $c = "readdir64" ascii
        $d = "hide_proc" ascii nocase
    condition:
        ($b and $c and $d) or ($a and $d)
}

rule Suspicious_Crypto_Miner_Config
{
    meta:
        description = "Stratum mining pool URLs in config-like files"
    strings:
        $a = "stratum+tcp://" ascii
        $b = "stratum+ssl://" ascii
        $c = "\"donate-level\"" ascii
    condition:
        ($a or $b) and $c
}
