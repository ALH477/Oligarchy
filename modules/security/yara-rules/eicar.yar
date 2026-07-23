// EICAR standard AV test string — fires on the industry test file only.
// Drop the EICAR test file in /tmp to verify the pipeline end-to-end:
//   printf '%s' 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' > /tmp/eicar.txt
rule EICAR_Test_File
{
    meta:
        description = "EICAR antivirus test file (not malware; pipeline test)"
        reference = "https://www.eicar.org/download-anti-malware-testfile/"
    strings:
        $eicar = "EICAR-STANDARD-ANTIVIRUS-TEST-FILE!"
    condition:
        $eicar
}
