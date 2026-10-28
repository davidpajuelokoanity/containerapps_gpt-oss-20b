<#
.SYNOPSIS
    Azure Container Apps のサーバーレスGPU上にOllama + gpt-oss:20bをAPIキー付きでデプロイする。

.DESCRIPTION
    Requirements: 1.1, 1.3, 1.4, 1.5, 2.3, 2.4, 2.5, 7.3, 7.4 (このタスクで実装する範囲)
    design.md の「全体フロー」「Azure CLIコマンドのシーケンス」に従い、以下の順序で処理する。
      1. `az account show` による認証済みセッションの確認（未ログイン時はエラー表示して中断）
      2. `.env` の読込・必須項目検証（欠落時はエラー表示して中断）、
         API_Key未設定時の自動生成と `.env` への書込
      3. 現在のサブスクリプションIDと `.env` の `AZURE_SUBSCRIPTION_ID` を比較し、
         不一致の場合は確認なしで `az account set --subscription` を実行して切り替える
      4. `az group create` によるResource_Groupの作成（既存の場合はAzure CLI自体の冪等性により再利用）
      5. `Test-RegionGpuSupported` によるDeployment_Region×GPU_Typeの組み合わせ検証
         （非対応時はエラー表示して中断）、`az containerapp env show`/`create` による
         Container_Apps_Environmentの作成/再利用、`az containerapp env workload-profile add`
         によるGPUワークロードプロファイルの追加（既存時は再利用）
      6. `ContainerAppSpec.psm1` の `New-ContainerAppYaml` によるYAML生成、
         `az containerapp show` による存在確認後の `az containerapp create --yaml`
         （新規作成時、失敗時はエラー表示して中断）または `az containerapp update --yaml`
         （既存更新時、失敗時もログに記録し後続手順を継続）
      7. `az containerapp show` によるPublic_EndpointのURL取得・表示
         （GPU割当や後続手順の成否に関わらず常に表示する）
      8. `az containerapp show`/`az containerapp logs show` のポーリングと
         `DeploymentMonitor.psm1` の `Get-ModelReadinessResult` によるモデル準備状態の判定
         （失敗/タイムアウト時はエラー表示して中断する）
      9. モデル準備確認成功時、`DeploymentMonitor.psm1` の `Write-DeploymentResult` による
         curl実行例の表示、および `Write-ResultEndpointFile` によるPublic_Endpoint情報
         （URL・API_Key・モデル名・curl実行例）の `result-endpoint.md` への書き出し
         （Pythonチャットクライアント `chat.py` がこのファイルを参照する）

    このスクリプトはトップレベルで実行された場合にのみメイン処理を実行する。
    Pesterテストから `. .\deploy.ps1` のようにドットソースされた場合は、
    ヘルパー関数の定義のみが行われ、副作用のあるメイン処理（Azure CLI呼び出し等）は実行されない。
#>

Set-StrictMode -Version Latest
# 注: 'Stop' にすると、Windows PowerShell 5.1 では外部コマンド（az）がstderrに
# 何らかの出力をした際に、`2>$null` でリダイレクトしていても $LASTEXITCODE の
# チェックより先にPowerShell側が終了エラーとしてスローしてしまうことが確認された
# （実機のAzure環境での検証により判明）。本スクリプトの外部コマンドのエラー判定は
# 明示的な $LASTEXITCODE チェックに一元化しているため、'Continue' に設定する。
# `throw` によるエラー送出は $ErrorActionPreference の値に関わらず常に終了エラーと
# なるため、既存のエラーハンドリング（try/catchでの中断）には影響しない。
$ErrorActionPreference = 'Continue'

# -----------------------------------------------------------------------------
# ヘルパー関数群（純粋関数・テスト容易な関数はここに定義する）
# -----------------------------------------------------------------------------

function Test-SubscriptionSwitchNeeded {
    <#
    .SYNOPSIS
        現在のサブスクリプションIDと目的のサブスクリプションIDを比較し、
        切替（`az account set --subscription`）が必要かどうかを判定する純粋関数。
    .DESCRIPTION
        design.md Property 14: 両者が不一致の場合にのみ「切替が必要（$true）」を返し、
        一致する場合は「切替不要（$false）」を返す。
    .PARAMETER CurrentSubscriptionId
        `az account show --query id -o tsv` 等で取得した現在のサブスクリプションID。
    .PARAMETER TargetSubscriptionId
        `.env` の `AZURE_SUBSCRIPTION_ID` に指定されたサブスクリプションID。
    .OUTPUTS
        bool ($true: 切替が必要, $false: 切替不要)
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentSubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$TargetSubscriptionId
    )

    return $CurrentSubscriptionId -ne $TargetSubscriptionId
}

function Assert-AzureLogin {
    <#
    .SYNOPSIS
        Azure CLIの認証済みセッションが存在することを確認する。
    .DESCRIPTION
        Requirements: 7.3
        `az account show` を実行し、非0終了コード（未ログイン等）の場合は
        エラーメッセージを表示してスクリプトを中断する（呼び出し元で `exit 1` させるため例外をスローする）。
    .OUTPUTS
        pscustomobject (`az account show` のJSON出力をパースしたオブジェクト)
    #>
    [CmdletBinding()]
    param()

    $accountJson = az account show --output json 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accountJson)) {
        Write-Error 'Azure CLIにログインしていません。`az login` を実行してください。'
        throw 'AzureCliNotLoggedIn'
    }

    return $accountJson | ConvertFrom-Json
}

function Switch-AzureSubscriptionIfNeeded {
    <#
    .SYNOPSIS
        現在のサブスクリプションIDが目的のサブスクリプションIDと異なる場合、
        利用者への確認を求めずに `az account set --subscription` を実行して切り替える。
    .DESCRIPTION
        Requirements: 7.4
        切替の必要性判定には `Test-SubscriptionSwitchNeeded`（Property 14の判定ロジック）を使用する。
    .PARAMETER CurrentSubscriptionId
        現在のサブスクリプションID。
    .PARAMETER TargetSubscriptionId
        `.env` の `AZURE_SUBSCRIPTION_ID` に指定されたサブスクリプションID。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CurrentSubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$TargetSubscriptionId
    )

    $needsSwitch = Test-SubscriptionSwitchNeeded -CurrentSubscriptionId $CurrentSubscriptionId -TargetSubscriptionId $TargetSubscriptionId

    if (-not $needsSwitch) {
        Write-Host "現在のサブスクリプション ($CurrentSubscriptionId) は .env の指定と一致しています。切替は不要です。"
        return
    }

    Write-Host "現在のサブスクリプション ($CurrentSubscriptionId) が .env の指定 ($TargetSubscriptionId) と異なるため、確認なしで切替を実行します。"

    az account set --subscription $TargetSubscriptionId

    if ($LASTEXITCODE -ne 0) {
        Write-Error "サブスクリプションの切替に失敗しました（対象ID: $TargetSubscriptionId）。"
        throw 'AzureSubscriptionSwitchFailed'
    }
}

function Initialize-EnvironmentConfiguration {
    <#
    .SYNOPSIS
        `.env` ファイルを読込・必須項目検証し、API_Keyが未設定の場合は自動生成して書き込む。
    .DESCRIPTION
        Requirements: 1.1, 1.3, 1.4, 1.5
        design.md の Environment_Configuration_File スキーマにおける必須キー一覧
        （API_KEYは含めない）に対して `Test-RequiredKeys` を実行し、
        欠落がある場合は欠落キー名を含むエラーメッセージを表示して中断する（例外をスロー）。
        API_KEYが未設定/空の場合は `New-ApiKey` で生成し、`Write-EnvFile` で `.env` へ書き込んで
        処理を継続する（エラーケースではない）。
    .PARAMETER EnvFilePath
        読込・書込対象の `.env` ファイルのパス。
    .OUTPUTS
        hashtable (検証・API_Key補完済みの環境設定値)
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvFilePath
    )

    $requiredKeys = @(
        'AZURE_SUBSCRIPTION_ID',
        'AZURE_TENANT_ID',
        'AZURE_RESOURCE_GROUP',
        'AZURE_LOCATION',
        'AZURE_CONTAINER_APPS_ENVIRONMENT',
        'AZURE_CONTAINER_APP_NAME',
        'AZURE_GPU_TYPE',
        'OLLAMA_MODEL'
    )

    $envValues = Read-EnvFile -Path $EnvFilePath

    $missingKeys = @(Test-RequiredKeys -Values $envValues -RequiredKeys $requiredKeys)

    if ($missingKeys.Count -gt 0) {
        Write-Error "`.env`に必須項目が設定されていません: $($missingKeys -join ', ')"
        throw 'EnvRequiredKeysMissing'
    }

    if ([string]::IsNullOrWhiteSpace([string]$envValues['API_KEY'])) {
        Write-Host 'API_KEYが未設定のため、自動生成して .env に書き込みます。'
        $envValues['API_KEY'] = New-ApiKey
        Write-EnvFile -Path $EnvFilePath -Values $envValues
    }

    return $envValues
}

function Initialize-ResourceGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    # Si el Resource Group ya existe, reutilizarlo sin comprobar ubicación
    az group show --name $ResourceGroupName --output json 2>$null | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Resource Group '$ResourceGroupName' ya existe. Se reutilizará."
        return
    }

    # Si no existe, crearlo en la ubicación indicada
    az group create --name $ResourceGroupName --location $Location --output json | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Error "No se pudo crear el Resource Group '$ResourceGroupName'."
        throw 'ResourceGroupCreateFailed'
    }

    Write-Host "Resource Group '$ResourceGroupName' creado correctamente."
}

function Assert-RegionGpuSupported {
    <#
    .SYNOPSIS
        Deployment_RegionとGPU_Typeの組み合わせが許可リストに含まれることを確認する。
    .DESCRIPTION
        Requirements: 2.4, 2.5
        `ResourceState.psm1` の `Test-RegionGpuSupported` を使用して許可リスト
        （`{westus3, swedencentral} × {T4, A100}`）と照合する。非対応の場合は、
        対応可能なリージョンとGPU種別の一覧を含むエラーメッセージを表示してスクリプトを中断する
        （呼び出し元で `exit 1` させるため例外をスローする）。
    .PARAMETER Region
        検証対象のDeployment_Region（`.env` の `AZURE_LOCATION`）。
    .PARAMETER GpuType
        検証対象のGPU_Type（`.env` の `AZURE_GPU_TYPE`）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Region,

        [Parameter(Mandatory = $true)]
        [string]$GpuType
    )

    $isSupported = Test-RegionGpuSupported -Region $Region -GpuType $GpuType

    if (-not $isSupported) {
        Write-Error "リージョン '$Region' とGPU種別 '$GpuType' の組み合わせはサポートされていません。対応可能な組み合わせ: westus3/T4, westus3/A100, swedencentral/T4, swedencentral/A100"
        throw 'RegionGpuUnsupported'
    }
}

function Initialize-ContainerAppsEnvironment {
    <#
    .SYNOPSIS
        Container_Apps_Environmentを作成する（既存の場合は再利用する）。
    .DESCRIPTION
        Requirements: 2.3
        design.md の「Azure CLIコマンドのシーケンス」手順4に従い、
        `az containerapp env show` で存在確認を行い、存在しない場合のみ
        `az containerapp env create` を実行する。存在有無から再利用/作成のいずれを
        行うかのログ表示には `Get-ResourceAction` を使用する。
        作成コマンドが非0終了コードを返した場合は、エラーメッセージを表示してスクリプトを中断する
        （呼び出し元で `exit 1` させるため例外をスローする）。
    .PARAMETER EnvironmentName
        作成（または再利用）対象のContainer_Apps_Environment名。
    .PARAMETER ResourceGroupName
        Container_Apps_Environmentが属するResource_Group名。
    .PARAMETER Location
        Container_Apps_Environmentを作成するAzureリージョン。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    $envJson = az containerapp env show --name $EnvironmentName --resource-group $ResourceGroupName --output json 2>$null
    $exists = ($LASTEXITCODE -eq 0) -and (-not [string]::IsNullOrWhiteSpace($envJson))

    $action = Get-ResourceAction -Exists $exists
    Write-Host "Container Apps Environment '$EnvironmentName' は既存有無の判定結果「$action」に従って処理します。"

    if (-not $exists) {
        az containerapp env create --name $EnvironmentName --resource-group $ResourceGroupName --location $Location --output json | Out-Null

        if ($LASTEXITCODE -ne 0) {
            Write-Error "Container_Apps_Environmentの作成に失敗しました（名前: $EnvironmentName, リージョン: $Location）。"
            throw 'ContainerAppsEnvironmentCreateFailed'
        }
    }

    Write-Host "Container Apps Environment '$EnvironmentName' の準備が完了しました。"
}

function Add-GpuWorkloadProfile {
    <#
    .SYNOPSIS
        Container_Apps_EnvironmentにGPUワークロードプロファイルを追加する（既存の場合は再利用する）。
    .DESCRIPTION
        Requirements: 2.3
        design.md の「Azure CLIコマンドのシーケンス」手順5に従い、`GpuProfile.psm1` の
        `Get-WorkloadProfile` から得たプロファイル定義を用いて
        `az containerapp env workload-profile add` を実行する。
        事前に `az containerapp env show` の `properties.workloadProfiles` を確認し、
        同名のプロファイルが既に存在する場合は再利用対象としてログに表示するが、
        `workload-profile add` コマンド自体は冪等（同名プロファイルへの再実行は更新として成功する）
        であるため、いずれの場合も実行する。
        コマンドが非0終了コードを返した場合は、エラーメッセージを表示してスクリプトを中断する
        （呼び出し元で `exit 1` させるため例外をスローする）。
    .PARAMETER EnvironmentName
        GPUワークロードプロファイルを追加する対象のContainer_Apps_Environment名。
    .PARAMETER ResourceGroupName
        Container_Apps_Environmentが属するResource_Group名。
    .PARAMETER WorkloadProfile
        `Get-WorkloadProfile` から取得したワークロードプロファイル定義
        （`ProfileType`/`FriendlyName`/`MaxCpu`/`MaxMemoryGiB`を含むhashtable）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [hashtable]$WorkloadProfile
    )

    $envJson = az containerapp env show --name $EnvironmentName --resource-group $ResourceGroupName --output json 2>$null
    $profileExists = $false

    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($envJson)) {
        $envObject = $envJson | ConvertFrom-Json
        $existingProfiles = @($envObject.properties.workloadProfiles)
        $profileExists = @(
    $existingProfiles | Where-Object {
        $_.name -eq $WorkloadProfile.FriendlyName -or
        $_.workloadProfileType -eq $WorkloadProfile.ProfileType
    }
        ).Count -gt 0
    }

    $action = Get-ResourceAction -Exists $profileExists
    Write-Host "GPUワークロードプロファイル '$($WorkloadProfile.FriendlyName)' は既存有無の判定結果「$action」に従って処理します。"

    # 注: `az containerapp env workload-profile add` は、design.mdの想定（同名プロファイルへの
    # 再実行は更新として成功する冪等なコマンド）とは異なり、実機のAzure環境での検証により、
    # 同名のワークロードプロファイルが既に存在する場合は
    # "Cannot add workload profile with name ... because it already exists in this environment"
    # というエラーで失敗することが判明した。そのため、既存の場合はコマンド自体をスキップする。
    if (-not $profileExists) {
        # 注: `Consumption-GPU-*` はサーバーレス（Consumption）プランのワークロードプロファイルであり、
        # 専用（Dedicated）プラン用のノード数指定（--min-nodes/--max-nodes）はサポートされない
        # （実機のAzure環境での検証により判明: "WorkloadProfilePropertyNotSupported" エラー）。
        # そのため、これらのパラメータは指定しない。
        az containerapp env workload-profile add `
            --name $EnvironmentName `
            --resource-group $ResourceGroupName `
            --workload-profile-name $WorkloadProfile.FriendlyName `
            --workload-profile-type $WorkloadProfile.ProfileType `
            --output json | Out-Null

        if ($LASTEXITCODE -ne 0) {
            Write-Error "GPUワークロードプロファイルの追加に失敗しました（プロファイル名: $($WorkloadProfile.FriendlyName)）。"
            throw 'WorkloadProfileAddFailed'
        }
    }

    Write-Host "GPUワークロードプロファイル '$($WorkloadProfile.FriendlyName)' の準備が完了しました。"
}

function Test-ShouldContinueAfterUpdate {
    <#
    .SYNOPSIS
        Container_App更新処理の成功/失敗を表すブール値を受け取り、更新後の後続手順
        （Public_Endpoint表示等）を実行するかどうかを判定する純粋関数。
    .DESCRIPTION
        design.md Property 13: 更新結果の値に関わらず常に「後続処理を実行する」
        （$true）という結果を返す。`update`失敗時であっても後続手順を継続する
        （Requirements: 7.2）という仕様を明示的かつテスト可能にするための関数であり、
        呼び出し元では例外をスローせずこの関数の戻り値に従って処理を継続する。
    .PARAMETER UpdateSucceeded
        Container_App更新処理（`az containerapp update`）が成功したかどうか。
    .OUTPUTS
        bool (常に $true)
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$UpdateSucceeded
    )

    return $true
}

function Publish-ContainerApp {
    <#
    .SYNOPSIS
        Container_Appを作成または更新する（既存の場合は更新する）。
    .DESCRIPTION
        Requirements: 3.1, 3.2, 3.3, 3.4, 4.1, 4.2, 4.3, 7.2
        design.md の「Azure CLIコマンドのシーケンス」手順6に従い、`ContainerAppSpec.psm1`の
        `New-ContainerAppSpec`でリソース定義（hashtable）を生成し、JSON化した上で
        `az containerapp show`で存在確認を行う。
        存在しない場合は`az rest --method PUT`でリソースを新規作成し、失敗時はエラー表示して
        スクリプトを中断する（呼び出し元で`exit 1`させるため例外をスローする）。
        既存の場合も同様に`az rest --method PUT`で更新するが、失敗しても
        `Test-ShouldContinueAfterUpdate`（Property 13の判定ロジック）の戻り値に従い、
        エラーをログに記録するのみで後続手順（Public_Endpoint表示等）を継続する
        （例外をスローしない）。

        注: 実機のAzure環境での検証により、`az containerapp create/update --yaml`コマンド自体の
        内部YAML→JSON変換処理に不具合があり、`az`にとって正しい構造のYAMLを渡しても
        "Bad Request: The JSON value could not be converted to System.Boolean" エラーで
        必ず失敗することが判明した（`az`バージョン2.87.0で確認）。この問題を回避するため、
        `--yaml`は使用せず、`az rest`でAzure Resource Manager REST APIを直接呼び出す方式を
        採用する（design.mdの初版方針からの変更点）。
    .PARAMETER Config
        `New-ContainerAppSpec`に渡す設定hashtable
        （`ModelName`/`GpuType`/`ApiKey`/`ContainerAppName`/`EnvironmentId`）。
    .PARAMETER ResourceGroupName
        Container_Appが属するResource_Group名。
    .PARAMETER Location
        Container Appを作成するAzureリージョン（`.env`の`AZURE_LOCATION`）。
    .PARAMETER SubscriptionId
        対象のAzureサブスクリプションID（ARM REST APIのリクエストURLの構築に使用する）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId
    )

    $containerAppName = [string]$Config.ContainerAppName

    $appJson = az containerapp show --name $containerAppName --resource-group $ResourceGroupName --output json 2>$null
    $exists = ($LASTEXITCODE -eq 0) -and (-not [string]::IsNullOrWhiteSpace($appJson))

    $action = Get-ResourceAction -Exists $exists
    Write-Host "Container App '$containerAppName' は既存有無の判定結果「$action」に従って処理します。"

    $spec = New-ContainerAppSpec -Config $Config -Location $Location
    $bodyJson = $spec | ConvertTo-Json -Depth 20

    $tempJsonFile = New-TemporaryFile
    $tempJsonPath = $tempJsonFile.FullName

    try {
        [System.IO.File]::WriteAllText($tempJsonPath, $bodyJson, (New-Object System.Text.UTF8Encoding($false)))

        $armUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/containerApps/${containerAppName}?api-version=2024-03-01"

        az rest --method PUT --uri $armUri --body "@$tempJsonPath" --output json | Out-Null
        $requestSucceeded = ($LASTEXITCODE -eq 0)

        if (-not $exists) {
            if (-not $requestSucceeded) {
                Write-Error "Container_Appの作成に失敗しました（名前: $containerAppName）。"
                throw 'ContainerAppCreateFailed'
            }

            Write-Host "Container App '$containerAppName' を作成しました。"
        }
        else {
            if (-not $requestSucceeded) {
                Write-Warning "Container_Appの更新に失敗しました（名前: $containerAppName）。エラー内容をログに記録し、後続手順を継続します。"
            }
            else {
                Write-Host "Container App '$containerAppName' を更新しました。"
            }

            # design.md Property 13: 更新結果の値に関わらず常に後続処理を実行する。
            $shouldContinue = Test-ShouldContinueAfterUpdate -UpdateSucceeded $requestSucceeded
            if (-not $shouldContinue) {
                # Test-ShouldContinueAfterUpdateは常に$trueを返す仕様のため、
                # このパスには到達しない（防御的コード）。
                throw 'ContainerAppUpdateFailed'
            }
        }
    }
    finally {
        Remove-Item -Path $tempJsonPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-PublicEndpointUrl {
    <#
    .SYNOPSIS
        Container_AppのPublic_Endpoint URLを取得する。
    .DESCRIPTION
        Requirements: 3.5
        design.md の「Azure CLIコマンドのシーケンス」手順7に従い、
        `az containerapp show --query properties.configuration.ingress.fqdn` でFQDNを取得し、
        `https://` を付与したURLを返す。このURLはGPU割当や後続手順（モデル準備確認等）の
        成否に関わらず常に表示する。
        コマンドが非0終了コードを返した場合、またはFQDNが空の場合は、
        エラーメッセージを表示してスクリプトを中断する（呼び出し元で `exit 1` させるため例外をスローする）。

        注: 実機のAzure環境での検証により、`Publish-ContainerApp`が`az rest --method PUT`で
        リソースを作成した直後は、結果整合性（eventual consistency）の影響でARM側の
        `properties.configuration.ingress.fqdn` がまだ反映されていない場合があることが判明した
        （初回の`az containerapp show`ではFQDNが空文字列として返る）。そのため、
        短い間隔で数回リトライする。
    .PARAMETER ContainerAppName
        FQDN取得対象のContainer_App名。
    .PARAMETER ResourceGroupName
        Container_Appが属するResource_Group名。
    .PARAMETER MaxAttempts
        リトライの最大試行回数（既定値: 6）。
    .PARAMETER RetryIntervalSeconds
        リトライ間隔（秒、既定値: 5）。
    .OUTPUTS
        string (`https://<fqdn>` 形式のPublic_Endpoint URL)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContainerAppName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 6,

        [Parameter(Mandatory = $false)]
        [int]$RetryIntervalSeconds = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $fqdn = az containerapp show --name $ContainerAppName --resource-group $ResourceGroupName --query 'properties.configuration.ingress.fqdn' --output tsv 2>$null
        $queryFailed = ($LASTEXITCODE -ne 0)

        if (-not $queryFailed -and -not [string]::IsNullOrWhiteSpace($fqdn)) {
            return "https://$($fqdn.Trim())"
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $RetryIntervalSeconds
        }
    }

    Write-Error "Public_EndpointのURL取得に失敗しました（Container_App名: $ContainerAppName）。"
    throw 'PublicEndpointFetchFailed'
}

function Wait-ForModelReady {
    <#
    .SYNOPSIS
        Container_Appのレプリカ状態をポーリングし、モデル準備状態を判定する。
    .DESCRIPTION
        Requirements: 5.1, 5.2, 5.3, 5.4
        design.md の「Azure CLIコマンドのシーケンス」手順8に従い、`az containerapp show` の
        `properties.runningStatus`（レプリカの稼働状態、Ollama_Container起動コマンド内の
        `ollama pull` 失敗時はレプリカが起動失敗/再起動を繰り返す）を一定間隔でポーリングし、
        状態文字列を `DeploymentMonitor.psm1` の `Get-ModelReadinessResult` に渡して
        "Error"/"Ready"/"Pending" に分類する。
        "Error" と判定された場合、または最大試行回数に達しても "Ready" と判定されなかった場合
        （タイムアウト）は、エラーメッセージを表示してスクリプトを中断する
        （呼び出し元で `exit 1` させるため例外をスローする）。
    .PARAMETER ContainerAppName
        状態確認対象のContainer_App名。
    .PARAMETER ResourceGroupName
        Container_Appが属するResource_Group名。
    .PARAMETER MaxAttempts
        ポーリングの最大試行回数（既定値: 10）。
    .PARAMETER PollIntervalSeconds
        ポーリング間隔（秒、既定値: 15）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContainerAppName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 10,

        [Parameter(Mandatory = $false)]
        [int]$PollIntervalSeconds = 15
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $statusJson = az containerapp show --name $ContainerAppName --resource-group $ResourceGroupName --query 'properties.runningStatus' --output tsv 2>$null
        $queryFailed = ($LASTEXITCODE -ne 0)

        # `az containerapp show` 自体の呼び出しが失敗した場合と、レプリカが失敗状態を示す
        # 場合（"Failed"/"Degraded"等）はモデル準備確認における失敗（"Failed"）として扱う。
        $state = if ($queryFailed -or [string]::IsNullOrWhiteSpace($statusJson)) {
            'Failed'
        }
        elseif ($statusJson.Trim() -in @('Failed', 'Degraded')) {
            'Failed'
        }
        elseif ($statusJson.Trim() -eq 'Running') {
            'Succeeded'
        }
        else {
            'Pulling'
        }

        $readiness = Get-ModelReadinessResult -State $state

        if ($readiness -eq 'Error') {
            Write-Error "モデルの準備確認に失敗しました（Container_App名: $ContainerAppName, 状態: $state）。'ollama pull' が失敗している可能性があります。"
            throw 'ModelReadinessCheckFailed'
        }

        if ($readiness -eq 'Ready') {
            Write-Host "モデルの準備が完了しました（Container_App名: $ContainerAppName）。"
            return
        }

        Write-Host "モデルの準備を確認中です（$attempt/$MaxAttempts 回目、状態: $state）。${PollIntervalSeconds}秒後に再確認します。"

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    }

    Write-Error "モデルの準備確認がタイムアウトしました（Container_App名: $ContainerAppName, 最大試行回数: $MaxAttempts）。"
    throw 'ModelReadinessCheckTimeout'
}

# -----------------------------------------------------------------------------
# メイン処理
# -----------------------------------------------------------------------------
# ドットソース（`. .\deploy.ps1`）でPesterテストからヘルパー関数のみを読み込む場合、
# 以下のメイン処理（Azure CLI呼び出しを含む副作用のある処理）は実行しない。
if ($MyInvocation.InvocationName -ne '.') {

    $repoRoot = $PSScriptRoot
    $envFilePath = Join-Path $repoRoot '.env'

    try {
        # 1. 認証確認（az account show）。未ログイン時はエラー表示して中断する。
        $currentAccount = Assert-AzureLogin
        $currentSubscriptionId = $currentAccount.id

        # 2. .env の読込・必須項目検証（欠落時はエラー表示して中断）、
        #    API_Key未設定時の自動生成と .env への書込。
        Import-Module (Join-Path $repoRoot 'modules\EnvFile.psm1') -Force
        $envValues = Initialize-EnvironmentConfiguration -EnvFilePath $envFilePath

        # 3. サブスクリプション切替（必要時のみ、確認なしで実行）。
        $targetSubscriptionId = [string]$envValues['AZURE_SUBSCRIPTION_ID']
        Switch-AzureSubscriptionIfNeeded -CurrentSubscriptionId $currentSubscriptionId -TargetSubscriptionId $targetSubscriptionId

        # 4. Resource_Groupの作成（既存の場合はAzure CLIの冪等性により再利用）。
        $resourceGroupName = [string]$envValues['AZURE_RESOURCE_GROUP']
        $location = [string]$envValues['AZURE_LOCATION']
        Initialize-ResourceGroup -ResourceGroupName $resourceGroupName -Location $location

        # 5. リージョン×GPU_Type検証とContainer_Apps_Environment作成/再利用、
        #    GPUワークロードプロファイル追加/再利用。
        Import-Module (Join-Path $repoRoot 'modules\ResourceState.psm1') -Force
        Import-Module (Join-Path $repoRoot 'modules\GpuProfile.psm1') -Force

        $gpuType = [string]$envValues['AZURE_GPU_TYPE']
        Assert-RegionGpuSupported -Region $location -GpuType $gpuType

        $environmentName = [string]$envValues['AZURE_CONTAINER_APPS_ENVIRONMENT']
        Initialize-ContainerAppsEnvironment -EnvironmentName $environmentName -ResourceGroupName $resourceGroupName -Location $location

        $workloadProfile = Get-WorkloadProfile -GpuType $gpuType
        Add-GpuWorkloadProfile -EnvironmentName $environmentName -ResourceGroupName $resourceGroupName -WorkloadProfile $workloadProfile

        # 6. Container_Appの作成/更新（既存の場合は更新。更新失敗時もログに記録し後続手順を継続）。
        Import-Module (Join-Path $repoRoot 'modules\ContainerAppSpec.psm1') -Force

        # 注: `az containerapp create --yaml` はYAML内に `properties.managedEnvironmentId`
        # （Container_Apps_EnvironmentのリソースID）が必須であることが実機のAzure環境での
        # 検証により判明したため、ここで取得してConfigに含める。
        $environmentId = az containerapp env show --name $environmentName --resource-group $resourceGroupName --query 'id' --output tsv 2>$null

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($environmentId)) {
            Write-Error "Container_Apps_EnvironmentのリソースID取得に失敗しました（名前: $environmentName）。"
            throw 'ContainerAppsEnvironmentIdFetchFailed'
        }

        $containerAppName = [string]$envValues['AZURE_CONTAINER_APP_NAME']
        $containerAppConfig = @{
            ModelName        = [string]$envValues['OLLAMA_MODEL']
            GpuType          = $gpuType
            ApiKey           = [string]$envValues['API_KEY']
            ContainerAppName = $containerAppName
            EnvironmentId    = $environmentId.Trim()
        }
        Publish-ContainerApp -Config $containerAppConfig -ResourceGroupName $resourceGroupName -Location $location -SubscriptionId $targetSubscriptionId

        # 7. Public_EndpointのURL取得・表示。
        #    design.md Property 13/Test-ShouldContinueAfterUpdateにより、Container_App更新が
        #    失敗した場合でもPublish-ContainerAppは例外をスローせず処理を継続するため、
        #    ここには常に到達し、GPU割当や後続手順の成否に関わらずURLを表示する。
        Import-Module (Join-Path $repoRoot 'modules\DeploymentMonitor.psm1') -Force

        $publicEndpointUrl = Get-PublicEndpointUrl -ContainerAppName $containerAppName -ResourceGroupName $resourceGroupName
        Write-Host "Public Endpoint: $publicEndpointUrl"

        $ollamaModelName = [string]$envValues['OLLAMA_MODEL']
        $resultEndpointFilePath = Join-Path $repoRoot 'result-endpoint.md'

        # Public_EndpointのURLは、GPU割当や後続手順（モデル準備確認等）の成否に関わらず
        # 常に result-endpoint.md へ書き出す（この時点ではまだ準備未完了、STATUS: Pending）。
        Write-ResultEndpointFile -Url $publicEndpointUrl -ApiKey ([string]$envValues['API_KEY']) -ModelName $ollamaModelName -IsComplete $false -Path $resultEndpointFilePath

        # 8. モデル準備状態のポーリング確認（失敗/タイムアウト時はエラー表示して中断）。
        Wait-ForModelReady -ContainerAppName $containerAppName -ResourceGroupName $resourceGroupName

        # 9. 成功時、curl実行例を表示する。result-endpoint.md も完了状態（curl実行例含む）で更新する。
        Write-DeploymentResult -IsComplete $true -Url $publicEndpointUrl -ApiKey ([string]$envValues['API_KEY'])
        Write-ResultEndpointFile -Url $publicEndpointUrl -ApiKey ([string]$envValues['API_KEY']) -ModelName $ollamaModelName -IsComplete $true -Path $resultEndpointFilePath
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}
