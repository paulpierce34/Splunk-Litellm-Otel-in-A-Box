$ErrorActionPreference = 'Stop'
$out = "$env:USERPROFILE\llmlab\admin-setup-result.txt"
try {
    # Classic firewall: allow podman/WSL subnet to the portproxy listener
    New-NetFirewallRule -DisplayName 'LLMLab-Enclave-In' `
        -Direction Inbound -Protocol TCP -LocalPort 18434 `
        -RemoteAddress 172.27.176.0/20 -Action Allow `
        -Profile Any -ErrorAction Stop | Out-Null

    # Hyper-V firewall (Windows 11 governs WSL/VM inbound separately)
    try {
        New-NetFirewallHyperVRule -DisplayName 'LLMLab-Enclave-HyperV' `
            -Direction Inbound -Protocol TCP -LocalPorts 18434 `
            -RemoteAddresses 172.27.176.0/20 -Action Allow `
            -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' `
            -ErrorAction Stop | Out-Null
        $hv = 'hv-rule: created'
    } catch { $hv = "hv-rule: skipped ($($_.Exception.Message))" }

    "OK`n$classic`n$hv" | Out-File $out -Encoding ascii
    "OK | $hv" | Out-File $out -Encoding ascii
} catch {
    "FAILED: $($_.Exception.Message)" | Out-File $out -Encoding ascii
}
