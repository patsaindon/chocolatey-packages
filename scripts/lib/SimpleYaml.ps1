# Minimal YAML reader for the flat, single-level-nesting manifests used in
# this repo (internalize.yml, metadata.yml — see docs/architecture.md section
# 6.1). Not a general-purpose YAML parser: no lists, no multi-line scalars,
# no anchors. Deliberately dependency-free so the workflows that read these
# manifests don't need to install a PSGallery module on the runner.
#
# Supports: `key: value` pairs, `#` comments, single level of indentation
# for a nested map (e.g. internalizeOptions:), quoted ("...") and bare
# scalars, and true/false coercion.

function ConvertFrom-SimpleYaml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string[]]$Lines
    )

    begin {
        $root = [ordered]@{}
        $stack = [System.Collections.Generic.List[object]]::new()
        $stack.Add([pscustomobject]@{ Indent = -1; Map = $root })
        $allLines = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($l in $Lines) { $allLines.Add($l) }
    }

    end {
        foreach ($rawLine in $allLines) {
            $line = $rawLine -replace '#.*$', ''
            if ($line.Trim() -eq '') { continue }
            if ($line -notmatch '^(?<indent>\s*)(?<key>[^:\s][^:]*):\s*(?<value>.*)$') { continue }

            $indent = $Matches.indent.Length
            $key = $Matches.key.Trim()
            $value = $Matches.value.Trim()

            while ($stack.Count -gt 1 -and $indent -le $stack[$stack.Count - 1].Indent) {
                $stack.RemoveAt($stack.Count - 1)
            }
            $currentMap = $stack[$stack.Count - 1].Map

            if ([string]::IsNullOrEmpty($value)) {
                $childMap = [ordered]@{}
                $currentMap[$key] = $childMap
                $stack.Add([pscustomobject]@{ Indent = $indent; Map = $childMap })
            } else {
                if ($value -match '^"(.*)"$') { $value = $Matches[1] }
                elseif ($value -match "^'(.*)'`$") { $value = $Matches[1] }
                elseif ($value -eq 'true') { $value = $true }
                elseif ($value -eq 'false') { $value = $false }
                $currentMap[$key] = $value
            }
        }
        return $root
    }
}
