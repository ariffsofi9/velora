# If unsigned scripts are blocked, invoke from a separately approved PowerShell
# process with -ExecutionPolicy Bypass; no persistent policy change is required.
# Validation only for an explicitly requested, unflavored Android pilot.
# Usage: & ./tool/validate_android_pilot_arguments.ps1 -PilotArguments @(
#   '--dart-define=VELORA_ANDROID_READ_ONLY_PILOT=true',
#   '--dart-define=VELORA_FIREBASE_PROJECT=velora-73222',
#   '--dart-define=VELORA_ANDROID_PILOT_BINDINGS=[["synthetic-user","synthetic-cafe"]]'
# )
# No build, launch, network, configuration write or child process occurs here.
# Normal builds use their separate existing workflow. An arbitrary direct
# Flutter/Gradle build can bypass this validator; this is not universal enforcement.
# Binding semantics mirror AndroidPilotPolicy.parse because that source imports
# Flutter. Offline differential tests in firebase_startup_config_test.dart keep
# this limited validation aligned with the authoritative Dart policy.
param([string[]]$PilotArguments = @())
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    if ($args.Count -ne 0 -or $PilotArguments.Count -ne 3) { throw 'Invalid argument count.' }
    $definitions = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
    $approved = @('VELORA_ANDROID_READ_ONLY_PILOT', 'VELORA_FIREBASE_PROJECT', 'VELORA_ANDROID_PILOT_BINDINGS')
    foreach ($argument in $PilotArguments) {
        if ($null -eq $argument -or $argument.Length -gt 8300 -or
            $argument -cnotmatch '(?s)\A--dart-define=([A-Z_]+)=(.*)\z') { throw 'Invalid argument.' }
        $key = $Matches[1]
        $value = $Matches[2]
        if ($key -cnotin $approved -or $definitions.ContainsKey($key)) { throw 'Invalid definition.' }
        $definitions.Add($key, $value)
    }
    if ($definitions['VELORA_ANDROID_READ_ONLY_PILOT'] -cne 'true' -or
        $definitions['VELORA_FIREBASE_PROJECT'] -cne 'velora-73222') { throw 'Invalid pilot intent or project.' }
    $raw = $definitions['VELORA_ANDROID_PILOT_BINDINGS']
    if ($raw.Length -eq 0 -or $raw.Length -gt 8192 -or $raw -cnotmatch '^\s*\[') { throw 'Invalid bindings.' }
    # Permit strict JSON array/string punctuation only. ConvertFrom-Json may
    # otherwise accept extensions such as single-quoted strings. Binding shape
    # and decoded identifier semantics remain validated below.
    $jsonString = '"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"'
    if ($raw -cnotmatch ('\A(?:[\[\], \t\r\n]|' + $jsonString + ')*\z') -or
        $raw -match ',\s*\]') { throw 'Invalid JSON.' }
    # Parse the complete raw document independently. Direct assignment preserves
    # the outer singleton array on Windows PowerShell 5.1; do not pipeline or
    # interpolate the input into another JSON document.
    $bindings = ConvertFrom-Json -InputObject $raw
    if ($bindings -isnot [array] -or $bindings.Count -lt 1 -or $bindings.Count -gt 20) { throw 'Invalid binding count.' }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    # Absolute anchors match the entire decoded ID, including its final character.
    foreach ($pair in $bindings) {
        if ($pair -isnot [array] -or $pair.Count -ne 2 -or
            $pair[0] -isnot [string] -or $pair[1] -isnot [string] -or
            $pair[0] -cnotmatch '\A[A-Za-z0-9_-]{1,128}\z' -or
            $pair[1] -cnotmatch '\A[A-Za-z0-9_-]{1,128}\z' -or
            -not $seen.Add($pair[0])) { throw 'Duplicate binding.' }
    }
    Write-Output 'PASS: restricted Android pilot arguments validated; no build or activation performed.'
    exit 0
} catch {
    # Never echo arguments, bindings, parser exceptions or sensitive values.
    Write-Output 'REJECTED: invalid restricted Android pilot arguments.'
    exit 1
}
