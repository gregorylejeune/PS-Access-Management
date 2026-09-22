function New-AccessFont {
    param([float]$Size = 10, [System.Drawing.FontStyle]$Style = 'Regular')
    New-Object System.Drawing.Font('Segoe UI', $Size, $Style)
}

function Add-FieldLabel {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width = 180)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Left = $X
    $label.Top = $Y
    $label.Width = $Width
    $label.Height = 22
    $label.Font = New-AccessFont 9
    [void]$Parent.Controls.Add($label)
    $label
}

function Add-FieldBox {
    param($Parent, [int]$X, [int]$Y, [int]$Width = 280)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Left = $X
    $box.Top = $Y
    $box.Width = $Width
    $box.Font = New-AccessFont 10
    [void]$Parent.Controls.Add($box)
    $box
}

function Add-Check {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width, [bool]$Checked)
    $box = New-Object System.Windows.Forms.CheckBox
    $box.Text = $Text
    $box.Left = $X
    $box.Top = $Y
    $box.Width = $Width
    $box.Height = 24
    $box.Checked = $Checked
    $box.Font = New-AccessFont 9
    [void]$Parent.Controls.Add($box)
    $box
}

function Add-PickList {
    param($Parent, [int]$X, [int]$Y, [int]$Width = 320)
    $list = New-Object System.Windows.Forms.ComboBox
    $list.Left = $X
    $list.Top = $Y
    $list.Width = $Width
    $list.DropDownStyle = 'DropDownList'
    $list.Font = New-AccessFont 9
    [void]$Parent.Controls.Add($list)
    $list
}

function Get-EnvironmentPick {
    param($Combo)
    if ($Combo.SelectedIndex -lt 0) { return $null }
    $Combo.SelectedItem
}

function Import-CredentialEnvironment {
    param([string]$Scope)
    foreach ($name in @('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN')) {
        $value = [Environment]::GetEnvironmentVariable($name, [System.EnvironmentVariableTarget]$Scope)
        if (-not [string]::IsNullOrEmpty($value)) {
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
}

function Read-NormalizationChoice {
    param($Owner, [string[]]$Issues, [string]$SecretId)
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Secret shape'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.ClientSize = New-Object System.Drawing.Size(560, 360)
    $dialog.Font = New-AccessFont 10
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false

    $copy = New-Object System.Windows.Forms.Label
    $copy.Text = "The secret is usable, but the names are not in the canonical shape. Values are not shown."
    $copy.Left = 16
    $copy.Top = 16
    $copy.Width = 520
    $copy.Height = 40
    [void]$dialog.Controls.Add($copy)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Left = 16
    $list.Top = 64
    $list.Width = 520
    $list.Height = 140
    foreach ($issue in @($Issues)) { [void]$list.Items.Add($issue) }
    [void]$dialog.Controls.Add($list)

    $confirm = Add-FieldBox $dialog 16 220 520
    $hint = Add-FieldLabel $dialog "Type the secret id ($SecretId) to write the canonical JSON back to AWS. Leave this blank to keep the repair in memory only." 16 250 520
    $hint.Height = 40

    $memory = New-Object System.Windows.Forms.Button
    $memory.Text = 'Use in memory'
    $memory.Left = 250
    $memory.Top = 310
    $memory.Width = 140
    $memory.DialogResult = 'OK'
    [void]$dialog.Controls.Add($memory)

    $write = New-Object System.Windows.Forms.Button
    $write.Text = 'Write back'
    $write.Left = 400
    $write.Top = 310
    $write.Width = 136
    $write.DialogResult = 'Yes'
    [void]$dialog.Controls.Add($write)
    $dialog.AcceptButton = $memory
    $dialog.CancelButton = $memory

    $choice = $dialog.ShowDialog($Owner)
    if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
        if ($confirm.Text.Trim() -ne $SecretId) {
            [void][System.Windows.Forms.MessageBox]::Show($Owner, 'The secret id did not match. Nothing was written back.', 'Secret shape')
            return 'Memory'
        }
        return 'WriteBack'
    }
    'Memory'
}

function Show-ConnectDialog {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'PS access management'
    $dialog.StartPosition = 'CenterScreen'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.ClientSize = New-Object System.Drawing.Size(760, 560)
    $dialog.Font = New-AccessFont 10
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.BackColor = [System.Drawing.Color]::FromArgb(246, 243, 236)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'Connect'
    $title.Font = New-AccessFont 18 'Bold'
    $title.Left = 20
    $title.Top = 16
    $title.Width = 700
    $title.Height = 34
    [void]$dialog.Controls.Add($title)

    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = 'Pick environment variables already on this machine, or type the secret name. Secret values are not shown. The saved identifier is protected with Windows DPAPI for your user only.'
    $intro.Left = 20
    $intro.Top = 54
    $intro.Width = 720
    $intro.Height = 44
    [void]$dialog.Controls.Add($intro)

    $choices = @(Get-AccessEnvironmentChoice)
    Add-FieldLabel $dialog 'Secret identifier' 20 110 700 | Out-Null
    $secretBox = Add-FieldBox $dialog 20 134 340
    $secretBox.Text = $script:DefaultSecretId
    $secretFromEnv = Add-Check $dialog 'Take it from an environment variable' 380 132 340 $false
    $secretList = Add-PickList $dialog 380 160 340
    foreach ($choice in $choices) { [void]$secretList.Items.Add($choice) }
    $secretList.DisplayMember = 'Display'
    $secretList.Enabled = $false

    Add-FieldLabel $dialog 'AWS region' 20 210 340 | Out-Null
    $regionBox = Add-FieldBox $dialog 20 234 340
    if ($env:AWS_REGION) { $regionBox.Text = $env:AWS_REGION }
    elseif ($env:AWS_DEFAULT_REGION) { $regionBox.Text = $env:AWS_DEFAULT_REGION }
    $regionFromEnv = Add-Check $dialog 'Take the region from an environment variable' 380 232 340 $false
    $regionList = Add-PickList $dialog 380 260 340
    foreach ($choice in $choices) { [void]$regionList.Items.Add($choice) }
    $regionList.DisplayMember = 'Display'
    $regionList.Enabled = $false

    Add-FieldLabel $dialog 'AWS profile environment variable (optional)' 20 310 700 | Out-Null
    $profileList = Add-PickList $dialog 20 334 340
    [void]$profileList.Items.Add('')
    foreach ($choice in $choices) { [void]$profileList.Items.Add($choice) }
    $profileList.DisplayMember = 'Display'

    $credentialScope = Add-PickList $dialog 380 334 160
    foreach ($scope in @('Process', 'User', 'Machine')) { [void]$credentialScope.Items.Add($scope) }
    $credentialScope.SelectedIndex = 0
    $loadKeys = Add-Check $dialog 'Load AWS credential variables from this scope without showing them' 20 374 700 $true

    $remember = Add-Check $dialog 'Remember this secret identifier on this Windows profile' 20 408 700 $true

    $saved = $null
    try { $saved = Unprotect-AccessSecretIdentifier } catch { $saved = $null }
    if ($saved) {
        if ($saved.secretId) { $secretBox.Text = [string]$saved.secretId }
        if ($saved.region) { $regionBox.Text = [string]$saved.region }
    }

    $secretFromEnv.Add_CheckedChanged({ $secretList.Enabled = $secretFromEnv.Checked; $secretBox.Enabled = -not $secretFromEnv.Checked }.GetNewClosure())
    $regionFromEnv.Add_CheckedChanged({ $regionList.Enabled = $regionFromEnv.Checked; $regionBox.Enabled = -not $regionFromEnv.Checked }.GetNewClosure())

    $connect = New-Object System.Windows.Forms.Button
    $connect.Text = 'Connect'
    $connect.Left = 600
    $connect.Top = 500
    $connect.Width = 130
    $connect.Height = 34
    $connect.BackColor = [System.Drawing.Color]::FromArgb(30, 58, 76)
    $connect.ForeColor = [System.Drawing.Color]::White
    $connect.FlatStyle = 'Flat'
    [void]$dialog.Controls.Add($connect)

    $state = @{ Connected = $false }
    $connect.Add_Click({
        try {
            $dialog.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $secretId = $secretBox.Text.Trim()
            $region = $regionBox.Text.Trim()
            $secretVariable = $null
            $regionVariable = $null
            $profileVariable = $null
            $profile = $null
            if ($secretFromEnv.Checked) {
                $pick = Get-EnvironmentPick $secretList
                if (-not $pick) { throw 'Choose the environment variable that holds the secret identifier.' }
                Import-AccessEnvironmentVariable -Name $pick.Name -Scope $pick.Scope
                $secretId = [Environment]::GetEnvironmentVariable($pick.Name, 'Process')
                $secretVariable = $pick.Name
            }
            if ($regionFromEnv.Checked) {
                $pick = Get-EnvironmentPick $regionList
                if (-not $pick) { throw 'Choose the environment variable that holds the AWS region.' }
                Import-AccessEnvironmentVariable -Name $pick.Name -Scope $pick.Scope
                $region = [Environment]::GetEnvironmentVariable($pick.Name, 'Process')
                $regionVariable = $pick.Name
            }
            $profilePick = Get-EnvironmentPick $profileList
            if ($profilePick -and $profilePick.Name) {
                Import-AccessEnvironmentVariable -Name $profilePick.Name -Scope $profilePick.Scope
                $profile = [Environment]::GetEnvironmentVariable($profilePick.Name, 'Process')
                $profileVariable = $profilePick.Name
            }
            if ($loadKeys.Checked) { Import-CredentialEnvironment $credentialScope.SelectedItem }
            if ([string]::IsNullOrWhiteSpace($secretId)) { throw 'A secret identifier is required.' }
            if ([string]::IsNullOrWhiteSpace($region)) { throw 'An AWS region is required.' }

            $probe = Get-AwsSecretString -SecretId $secretId -Region $region
            $normalized = ConvertTo-NormalizedAccessSecret -Json $probe
            $probe = $null
            if (-not $normalized.IsValid) { throw ("The secret is missing: " + ($normalized.Missing -join ', ')) }
            $repair = 'Memory'
            $allowWrite = $false
            if (-not $normalized.IsCanonical) {
                $repair = Read-NormalizationChoice $dialog @($normalized.Issues) $secretId
                if ($repair -eq 'WriteBack') { $allowWrite = $true }
            }
            $normalized.RepairedJson = $null
            if ($remember.Checked) {
                Protect-AccessSecretIdentifier -SecretId $secretId -Region $region -SecretIdVariable $secretVariable -RegionVariable $regionVariable -ProfileVariable $profileVariable | Out-Null
            }
            Connect-AccessManagement -SecretId $secretId -Region $region -AwsProfile $profile -RepairChoice $repair -AllowRepairWrite:$allowWrite | Out-Null
            $state.Connected = $true
            $dialog.Close()
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, 'Could not connect')
        } finally {
            $dialog.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }.GetNewClosure())
    [void]$dialog.ShowDialog()
    $dialog.Dispose()
    [bool]$state.Connected
}

function Get-SelectedActionKey {
    if ($script:Ui.ActionList.SelectedIndex -lt 0) { return $null }
    $script:Ui.ActionList.SelectedItem.Key
}

function Set-ActionFields {
    $panel = $script:Ui.ActionPanel
    $panel.Controls.Clear()
    $script:Ui.Fields = @{}
    $key = Get-SelectedActionKey
    $y = 8
    switch ($key) {
        'AddAlias' {
            Add-FieldLabel $panel 'Alias' 8 $y 140 | Out-Null
            $script:Ui.Fields.Alias = Add-FieldBox $panel 150 $y 360
            $script:Ui.Fields.MakePrimary = Add-Check $panel 'Make this the primary SMTP address' 530 ($y - 2) 280 $false
        }
        'ChangeName' {
            Add-FieldLabel $panel 'First name' 8 $y 140 | Out-Null
            $script:Ui.Fields.GivenName = Add-FieldBox $panel 150 $y 220
            Add-FieldLabel $panel 'Last name' 390 $y 90 | Out-Null
            $script:Ui.Fields.Surname = Add-FieldBox $panel 480 $y 220
            $script:Ui.Fields.UpdateDisplayName = Add-Check $panel 'Update display name' 150 ($y + 32) 220 $true
            $script:Ui.Fields.RenameCn = Add-Check $panel 'Also rename the AD common name' 390 ($y + 32) 280 $false
            if ($script:Ui.User) {
                $script:Ui.Fields.GivenName.Text = [string]$script:Ui.User.GivenName
                $script:Ui.Fields.Surname.Text = [string]$script:Ui.User.Surname
            }
        }
        'ReEnable' {
            $note = Add-FieldLabel $panel 'Re-enable clears the disabled flag and a lockout. It does not set a password. The person uses the self-service portal.' 8 $y 820
            $note.Height = 44
        }
        'Unblock' {
            $note = Add-FieldLabel $panel 'Unblock only clears a bad-password lockout. A disabled account stays disabled until you re-enable it.' 8 $y 820
            $note.Height = 44
        }
        'SetMfa' {
            Add-FieldLabel $panel 'What to change' 8 $y 140 | Out-Null
            $mode = Add-PickList $panel 150 $y 280
            [void]$mode.Items.Add('Per-user MFA state')
            [void]$mode.Items.Add('On-prem extension attribute')
            $mode.SelectedIndex = 0
            $script:Ui.Fields.Mode = $mode
            $state = Add-PickList $panel 450 $y 180
            foreach ($item in @('enabled', 'enforced', 'disabled')) { [void]$state.Items.Add($item) }
            $state.SelectedIndex = 0
            $script:Ui.Fields.State = $state
            $ext = Add-PickList $panel 450 ($y + 36) 180
            for ($i = 1; $i -le 15; $i++) { [void]$ext.Items.Add("extensionAttribute$i") }
            $ext.SelectedIndex = 0
            $ext.Visible = $false
            $script:Ui.Fields.ExtensionAttribute = $ext
            $value = Add-FieldBox $panel 640 ($y + 36) 180
            $value.Visible = $false
            $script:Ui.Fields.ExtensionValue = $value
            $fields = $script:Ui.Fields
            $mode.Add_SelectedIndexChanged({
                $cloud = ($fields.Mode.SelectedIndex -eq 0)
                $fields.State.Visible = $cloud
                $fields.ExtensionAttribute.Visible = -not $cloud
                $fields.ExtensionValue.Visible = -not $cloud
            }.GetNewClosure())
        }
        'RegenerateEmail' {
            Add-FieldLabel $panel 'Pattern' 8 $y 80 | Out-Null
            $pattern = Add-PickList $panel 90 $y 180
            foreach ($item in @('GivenDotSurname', 'SurnameDotGiven', 'FirstInitialSurname')) { [void]$pattern.Items.Add($item) }
            $pattern.SelectedIndex = 0
            $script:Ui.Fields.Pattern = $pattern
            Add-FieldLabel $panel 'Domain' 290 $y 70 | Out-Null
            $script:Ui.Fields.Domain = Add-FieldBox $panel 360 $y 180
            $script:Ui.Fields.KeepOldAsAlias = Add-Check $panel 'Keep the old address as an alias' 560 ($y - 2) 260 $true
        }
        'MoveOu' {
            Add-FieldLabel $panel 'Target OU' 8 $y 90 | Out-Null
            $script:Ui.Fields.TargetOu = Add-FieldBox $panel 100 $y 720
        }
        'ChangeUsername' {
            Add-FieldLabel $panel 'sAMAccountName' 8 $y 120 | Out-Null
            $script:Ui.Fields.NewSamAccountName = Add-FieldBox $panel 140 $y 180
            Add-FieldLabel $panel 'UPN' 340 $y 40 | Out-Null
            $script:Ui.Fields.NewUserPrincipalName = Add-FieldBox $panel 390 $y 250
            $script:Ui.Fields.KeepOldUpnAsAlias = Add-Check $panel 'Keep the old UPN as an alias' 140 ($y + 32) 250 $true
            $script:Ui.Fields.UpdateMail = Add-Check $panel 'Also make the new UPN the primary email' 410 ($y + 32) 320 $false
        }
    }
}

function Get-FormParameters {
    $parameters = @{}
    foreach ($name in @($script:Ui.Fields.Keys)) {
        $control = $script:Ui.Fields[$name]
        if ($control -is [System.Windows.Forms.CheckBox]) { $parameters[$name] = [bool]$control.Checked }
        elseif ($control -is [System.Windows.Forms.ComboBox]) {
            if ($name -eq 'Mode') {
                $parameters[$name] = $(if ($control.SelectedIndex -eq 1) { 'ExtensionAttribute' } else { 'PerUserMfaState' })
            } else { $parameters[$name] = [string]$control.SelectedItem }
        } else { $parameters[$name] = $control.Text.Trim() }
    }
    $parameters
}

function Show-UserCard {
    param($User)
    $lines = @(
        $User.DisplayName
        $User.UserPrincipalName
        ("Username: {0}" -f $User.SamAccountName)
        ("OU: {0}" -f $User.OrganizationalUnit)
        ("On-prem GUID: {0}" -f $User.OnPremObjectGuid)
        ("Entra ID: {0}" -f $User.EntraObjectId)
        ("Synced: {0}    On-prem enabled: {1}    Entra enabled: {2}    Locked: {3}" -f $User.OnPremisesSyncEnabled, $User.EnabledOnPrem, $User.EnabledEntra, $User.LockedOut)
        ("Mail: {0}" -f $User.Mail)
        ("MFA state: {0}" -f $(if ($User.PerUserMfaState) { $User.PerUserMfaState } else { 'not read' }))
    )
    $script:Ui.UserCard.Text = ($lines -join [Environment]::NewLine)
}

function Clear-Preview {
    $script:Ui.Preview.Items.Clear()
    $script:Ui.Messages.Text = ''
    $script:Ui.ApplyCheck.Checked = $false
    $script:Ui.ApplyButton.Enabled = $false
    $script:Ui.PrivilegedCheck.Visible = $false
    $script:Ui.PrivilegedCheck.Checked = $false
}

function Show-AccessManagementForm {
    <#
    .SYNOPSIS
        Opens the operator form.
    #>
    [CmdletBinding()]
    param()

    if ($env:OS -ne 'Windows_NT') {
        throw 'The operator form runs on Windows. Use the catalog script from a domain workstation too; AD, DPAPI, and the form are Windows-only.'
    }
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        $exe = 'powershell.exe'
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { $exe = 'pwsh.exe' }
        & $exe -NoProfile -STA -Command "Import-Module '$script:ModuleRoot\PSAccessManagement.psd1' -Force; Show-AccessManagementForm"
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    if (-not (Show-ConnectDialog)) { return }
    if ($null -eq $script:AccessSession) { return }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'PS access management'
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object System.Drawing.Size(1080, 760)
    $form.MinimumSize = New-Object System.Drawing.Size(980, 700)
    $form.Font = New-AccessFont 10
    $form.BackColor = [System.Drawing.Color]::FromArgb(246, 243, 236)

    $header = New-Object System.Windows.Forms.Label
    $header.Dock = 'Top'
    $header.Height = 56
    $header.BackColor = [System.Drawing.Color]::FromArgb(30, 58, 76)
    $header.ForeColor = [System.Drawing.Color]::White
    $header.Font = New-AccessFont 12 'Bold'
    $header.Padding = New-Object System.Windows.Forms.Padding(16, 8, 0, 0)
    $header.Text = "PS access management    $($script:AccessSession.OperatorSam)    service $($script:AccessSession.ServiceAccountUpn)"
    [void]$form.Controls.Add($header)

    $script:Ui = @{ Fields = @{} }
    $script:Ui.User = $null

    $searchLabel = Add-FieldLabel $form 'Find a person' 16 72 100
    $searchBox = Add-FieldBox $form 120 70 520
    $searchButton = New-Object System.Windows.Forms.Button
    $searchButton.Text = 'Search'
    $searchButton.Left = 650
    $searchButton.Top = 68
    $searchButton.Width = 100
    $searchButton.Height = 28
    [void]$form.Controls.Add($searchButton)
    $userPick = Add-PickList $form 760 70 300
    $script:Ui.UserPick = $userPick

    $card = New-Object System.Windows.Forms.Label
    $card.Left = 16
    $card.Top = 108
    $card.Width = 1048
    $card.Height = 132
    $card.BorderStyle = 'FixedSingle'
    $card.BackColor = [System.Drawing.Color]::White
    $card.Font = New-AccessFont 9
    $card.Text = 'Search by user principal name, username, or display name.'
    [void]$form.Controls.Add($card)
    $script:Ui.UserCard = $card

    Add-FieldLabel $form 'Action' 16 252 60 | Out-Null
    $actions = Add-PickList $form 80 250 320
    foreach ($action in @(
        @{ Key = 'AddAlias'; Text = 'Add an alias' }
        @{ Key = 'ChangeName'; Text = 'Change first or last name' }
        @{ Key = 'ReEnable'; Text = 'Re-enable an account' }
        @{ Key = 'Unblock'; Text = 'Unblock a locked account' }
        @{ Key = 'SetMfa'; Text = 'Change a multi-factor setting' }
        @{ Key = 'RegenerateEmail'; Text = 'Regenerate the email address' }
        @{ Key = 'MoveOu'; Text = 'Move to another OU' }
        @{ Key = 'ChangeUsername'; Text = 'Change the username' }
    )) {
        [void]$actions.Items.Add([pscustomobject]$action)
    }
    $actions.DisplayMember = 'Text'
    $actions.SelectedIndex = 0
    $script:Ui.ActionList = $actions

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Left = 16
    $panel.Top = 286
    $panel.Width = 1048
    $panel.Height = 78
    $panel.BackColor = [System.Drawing.Color]::FromArgb(255, 252, 247)
    $panel.BorderStyle = 'FixedSingle'
    [void]$form.Controls.Add($panel)
    $script:Ui.ActionPanel = $panel

    $preview = New-Object System.Windows.Forms.ListView
    $preview.Left = 16
    $preview.Top = 374
    $preview.Width = 1048
    $preview.Height = 160
    $preview.View = 'Details'
    $preview.FullRowSelect = $true
    $preview.GridLines = $true
    [void]$preview.Columns.Add('System', 110)
    [void]$preview.Columns.Add('Attribute', 180)
    [void]$preview.Columns.Add('Before', 360)
    [void]$preview.Columns.Add('After', 360)
    [void]$form.Controls.Add($preview)
    $script:Ui.Preview = $preview

    $messages = New-Object System.Windows.Forms.Label
    $messages.Left = 16
    $messages.Top = 540
    $messages.Width = 1048
    $messages.Height = 36
    [void]$form.Controls.Add($messages)
    $script:Ui.Messages = $messages

    $privileged = Add-Check $form 'I am intentionally changing a privileged account' 16 578 420 $false
    $privileged.Visible = $false
    $script:Ui.PrivilegedCheck = $privileged
    $applyCheck = Add-Check $form 'Apply the previewed change' 450 578 250 $false
    $script:Ui.ApplyCheck = $applyCheck

    $previewButton = New-Object System.Windows.Forms.Button
    $previewButton.Text = 'Preview'
    $previewButton.Left = 760
    $previewButton.Top = 574
    $previewButton.Width = 140
    $previewButton.Height = 32
    [void]$form.Controls.Add($previewButton)

    $applyButton = New-Object System.Windows.Forms.Button
    $applyButton.Text = 'Apply'
    $applyButton.Left = 910
    $applyButton.Top = 574
    $applyButton.Width = 140
    $applyButton.Height = 32
    $applyButton.Enabled = $false
    $applyButton.BackColor = [System.Drawing.Color]::FromArgb(143, 45, 45)
    $applyButton.ForeColor = [System.Drawing.Color]::White
    $applyButton.FlatStyle = 'Flat'
    [void]$form.Controls.Add($applyButton)
    $script:Ui.ApplyButton = $applyButton

    $log = New-Object System.Windows.Forms.TextBox
    $log.Left = 16
    $log.Top = 616
    $log.Width = 1048
    $log.Height = 120
    $log.Multiline = $true
    $log.ScrollBars = 'Vertical'
    $log.ReadOnly = $true
    $log.Font = New-AccessFont 8
    [void]$form.Controls.Add($log)
    $script:Ui.Log = $log

    $ui = $script:Ui
    $writeLog = {
        param([string]$Line)
        $log.AppendText(("[{0}] {1}{2}" -f (Get-Date).ToString('HH:mm:ss'), $Line, [Environment]::NewLine))
    }.GetNewClosure()
    $writeLog.Invoke("Connected. Session $($script:AccessSession.SessionId). Audit target $(Get-SqlTargetLabel $script:AccessSession.AuditConnectionString).")

    $actions.Add_SelectedIndexChanged({ Clear-Preview; Set-ActionFields }.GetNewClosure())
    Set-ActionFields

    $searchButton.Add_Click({
        try {
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            Clear-Preview
            $found = @(Find-AccessUser -Query $searchBox.Text)
            $userPick.Items.Clear()
            $ui.User = $null
            if ($found.Count -eq 0) {
                $card.Text = 'No matching user.'
                $writeLog.Invoke("No user matched $($searchBox.Text).")
                return
            }
            foreach ($person in $found) {
                $label = '{0}  |  {1}' -f $person.DisplayName, $person.UserPrincipalName
                [void]$userPick.Items.Add([pscustomobject]@{ Label = $label; User = $person })
            }
            $userPick.DisplayMember = 'Label'
            $userPick.SelectedIndex = 0
            $writeLog.Invoke("Search returned $($found.Count) user(s).")
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Search failed')
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }.GetNewClosure())
    $searchBox.Add_KeyDown({
        if ($_.KeyCode -eq 'Enter') { $searchButton.PerformClick(); $_.SuppressKeyPress = $true }
    }.GetNewClosure())
    $userPick.Add_SelectedIndexChanged({
        if ($userPick.SelectedIndex -lt 0) { return }
        $ui.User = $userPick.SelectedItem.User
        Show-UserCard $ui.User
        Clear-Preview
        Set-ActionFields
    }.GetNewClosure())

    $previewButton.Add_Click({
        try {
            if (-not $ui.User) { throw 'Search for a person first.' }
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            Clear-Preview
            $plan = Get-AccessOperationPlan -User $ui.User -Operation (Get-SelectedActionKey) -Parameters (Get-FormParameters)
            if ($plan.Error) { throw $plan.Error }
            foreach ($change in @($plan.Changes)) {
                $item = New-Object System.Windows.Forms.ListViewItem([string]$change.System)
                [void]$item.SubItems.Add([string]$change.Attribute)
                [void]$item.SubItems.Add([string]$change.Before)
                [void]$item.SubItems.Add([string]$change.After)
                [void]$preview.Items.Add($item)
            }
            $ui.Messages.Text = (@($plan.Messages) -join ' ')
            $ui.PrivilegedCheck.Visible = [bool]$plan.RequiresPrivilegedConfirm
            $ui.ApplyButton.Enabled = $true
            $writeLog.Invoke("Preview ready for $(Get-SelectedActionKey).")
        } catch {
            $ui.ApplyButton.Enabled = $false
            [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Preview')
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }.GetNewClosure())

    $applyButton.Add_Click({
        try {
            if (-not $ui.ApplyCheck.Checked) { throw 'Check Apply the previewed change first.' }
            if ($ui.PrivilegedCheck.Visible -and -not $ui.PrivilegedCheck.Checked) { throw 'This account is privileged. Check the confirmation box.' }
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $result = Invoke-AccessOperation -User $ui.User -Operation (Get-SelectedActionKey) -Parameters (Get-FormParameters) -PrivilegedConfirmed:($ui.PrivilegedCheck.Checked)
            $writeLog.Invoke("Applied $(Get-SelectedActionKey). Audit correlation $($result.CorrelationId).")
            $ui.User = Get-RefreshedAccessUser $ui.User
            Show-UserCard $ui.User
            Clear-Preview
            [void][System.Windows.Forms.MessageBox]::Show($form, "Change recorded. Correlation $($result.CorrelationId).", 'Applied')
        } catch {
            $writeLog.Invoke("Apply failed. $($_.Exception.Message)")
            [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Apply failed')
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }.GetNewClosure())

    $form.Add_FormClosed({ Disconnect-AccessManagement }.GetNewClosure())
    [void]$form.ShowDialog()
    $form.Dispose()
}
