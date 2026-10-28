<#
.SYNOPSIS
    GPU種別からContainer Appsワークロードプロファイル定義へのマッピングを行う純粋関数群。

.DESCRIPTION
    Requirements: 3.2
    - Get-WorkloadProfile: GPU_Type（`T4`/`A100`）からワークロードプロファイル定義
      （ProfileType/FriendlyName/MaxCpu/MaxMemoryGiB）を返す。
#>

Set-StrictMode -Version Latest

# GPU種別ごとのワークロードプロファイル定義（design.md の GPUワークロードプロファイルのマッピング参照）
$script:WorkloadProfiles = @{
    'T4'   = @{
        ProfileType   = 'Consumption-GPU-NC8as-T4'
        FriendlyName  = 't4'
        MaxCpu        = 8
        MaxMemoryGiB  = 56
    }
    'A100' = @{
        ProfileType   = 'Consumption-GPU-NC24-A100'
        FriendlyName  = 'a100'
        MaxCpu        = 24
        MaxMemoryGiB  = 220
    }
}

function Get-WorkloadProfile {
    <#
    .SYNOPSIS
        GPU_Typeからワークロードプロファイル定義を返す。
    .PARAMETER GpuType
        GPU種別文字列（"T4" または "A100"）。
    .OUTPUTS
        hashtable (@{ProfileType; FriendlyName; MaxCpu; MaxMemoryGiB})
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GpuType
    )

    if (-not $script:WorkloadProfiles.ContainsKey($GpuType)) {
        throw "Unsupported GPU type: $GpuType"
    }

    # 呼び出し元による意図しない変更を防ぐため、格納済みhashtableのコピーを返す
    return @{
        ProfileType  = $script:WorkloadProfiles[$GpuType].ProfileType
        FriendlyName = $script:WorkloadProfiles[$GpuType].FriendlyName
        MaxCpu       = $script:WorkloadProfiles[$GpuType].MaxCpu
        MaxMemoryGiB = $script:WorkloadProfiles[$GpuType].MaxMemoryGiB
    }
}

Export-ModuleMember -Function Get-WorkloadProfile