# RustDesk msi project

Use Visual Studio 2022 to compile this project.

This project is mainly derived from <https://github.com/MediaPortal/MediaPortal-2.git> .

## Steps

1. `python preprocess.py`, see `python preprocess.py -h` for help.
2. Build the .sln solution.

Run `msiexec /i package.msi /l*v install.log` to record the log.

## Windows deployment

The MSI is built as `perMachine`, so it can be deployed on another Windows host with an elevated
context. For unattended rollout use:

```bat
msiexec /i Package.msi /qn /norestart /l*v install.log LAUNCH_TRAY_APP=N DESKTOPSHORTCUTS=1 STARTMENUSHORTCUTS=1 PRINTER=1
```

Recommended usage:

1. Copy the built MSI to the target host or a network share.
2. Run the command above from an elevated prompt, Intune, SCCM, GPO startup script, or RMM tool.
3. Collect `install.log` if the deployment fails.

The repository also includes `deploy-windows.cmd` for a ready-to-run silent install wrapper.

### WinRM deployment to a remote Windows host

For a managed host such as `program-2.gubernia.local`, use the WinRM wrapper:

```powershell
PowerShell -ExecutionPolicy Bypass -File .\deploy-winrm.ps1
```

By default it deploys `Package\bin\x64\Release\ru-ru\Package.msi` to `program-2.gubernia.local`,
copies the MSI to the remote `Windows\Temp` directory, runs a silent install, and copies the
remote MSI log back to your local `%TEMP%` directory.
After the MSI completes, the script also runs `--after-install` on the installed executable to
finish service and startup wiring.

Exit codes `3010` and `1641` are treated as success with reboot required.

To deploy to another host or use alternate credentials:

```powershell
PowerShell -ExecutionPolicy Bypass -File .\deploy-winrm.ps1 -ComputerName program-2.gubernia.local -Credential (Get-Credential)
```

### Set a fixed permanent password on the remote host

If the machine is already installed and joined, use:

```powershell
PowerShell -ExecutionPolicy Bypass -File .\deploy-set-password-winrm.ps1 -ComputerName program-2.gubernia.local -Password "<deployment-password>"
```

Alternatively, set the password only for the current process and keep it out of command history:

```powershell
$env:GUBERNIA_DESKTOP_PASSWORD = Read-Host "Gubernia Desktop password"
PowerShell -ExecutionPolicy Bypass -File .\deploy-set-password-winrm.ps1 -ComputerName program-2.gubernia.local -Credential (Get-Credential)
Remove-Item Env:\GUBERNIA_DESKTOP_PASSWORD
```

#### Permanent password diagnostics notes

Observed on `program-2.gubernia.local`:

- Running `"C:\Program Files\Gubernia Desktop\Gubernia Desktop.exe" --password <deployment-password>`
  directly from a WinRM session can fail with `reset by the peer`.
- The process may still return exit code `0`, so exit code alone is not a reliable confirmation.
- The IPC server rejected the WinRM process because it ran as the WinRM user in session `0`,
  while the desktop/server IPC expected either `SYSTEM` or the active desktop session.
- The service runs as `LocalSystem`, but RustDesk/Gubernia Desktop patches the config path from
  `system32\config\systemprofile` to `ServiceProfiles\LocalService`.

The persistent service config is:

```text
C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\Gubernia Desktop\config\Gubernia Desktop.toml
C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\Gubernia Desktop\config\Gubernia Desktop2.toml
```

Do not validate the service password state only under:

```text
%APPDATA%\Gubernia Desktop
C:\Windows\ServiceProfiles\LocalSystem\AppData\Roaming\Gubernia Desktop
C:\Windows\System32\config\systemprofile\AppData\Roaming\Gubernia Desktop
C:\ProgramData\Gubernia Desktop
```

The reliable non-interactive deployment path is to run `--password` through a temporary scheduled
task as `SYSTEM`, then verify `Gubernia Desktop.toml`. The deploy scripts do this and validate:

```text
password == "01" + base64(sha256(plain_password + salt))
```

Do not commit real deployment passwords, salts, hashes, private keys, host inventories, or MSI logs.

### Mass deployment for many Windows hosts

Use `deploy-mass-winrm.ps1` to remove the old RustDesk client, install the branded MSI, set the
fixed password, and keep per-host success/failure logs.

Example:

```powershell
PowerShell -ExecutionPolicy Bypass -File .\deploy-mass-winrm.ps1 -ComputerListPath .\hosts.txt -Password "<deployment-password>" -Credential (Get-Credential)
```

If you want to retry only failed hosts from the previous run:

```powershell
PowerShell -ExecutionPolicy Bypass -File .\deploy-mass-winrm.ps1 -RetryFailed -Password "<deployment-password>" -Credential (Get-Credential)
```

Outputs:
- `logs\<timestamp>\summary.csv`
- `logs\<timestamp>\run.log`
- `failed-hosts.txt`
- `logs\<timestamp>\success-hosts.txt`

### GPO deployment for all workstations

For domain-wide workstation rollout, publish the MSI and startup script into SYSVOL:

```text
\\sup.gubernia.local\SYSVOL\gubernia.local\scripts\GuberniaDesktop\Package.msi
\\sup.gubernia.local\SYSVOL\gubernia.local\scripts\GuberniaDesktop\install-gubernia-desktop-gpo.ps1
```

The script is idempotent:

1. If Gubernia Desktop is installed and the permanent password verifies, it exits without changes.
2. If old RustDesk is installed, it stops the old runtime and uninstalls it.
3. If Gubernia Desktop is missing, it silently installs the MSI.
4. It runs `Gubernia Desktop.exe --after-install`.
5. It sets and verifies the permanent password.
6. It writes client-side logs to `C:\ProgramData\GuberniaDesktopDeploy\`.

The deployment password must be supplied outside version control, either through the
`-Password` parameter when testing manually or through a secure local deployment mechanism.

### Build hosts.txt from installed machines

If you already have a source list of computers and want to generate the `hosts.txt` file with only
the hosts where RustDesk/Gubernia Desktop is currently installed, use:

```powershell
PowerShell -ExecutionPolicy Bypass -File .\generate-hosts-winrm.ps1 -ComputerListPath .\hosts-source.txt
```

The script writes the filtered DNS names to `hosts.txt` in the same folder, which can then be fed
directly into `deploy-mass-winrm.ps1`.

### Build hosts-source.txt from Active Directory

If you want to start from AD instead of a manual list, generate `hosts-source.txt` first:

```powershell
PowerShell -ExecutionPolicy Bypass -File .\generate-hosts-source-from-ad.ps1 -DomainName gubernia.local
```

This requires the `ActiveDirectory` PowerShell module and writes all enabled AD computer DNS names
for the domain into `hosts-source.txt`. You can then run `generate-hosts-winrm.ps1` against that
file.

## Usage

1. Put the custom dialog bitmaps in "Resources" directory. The supported bitmaps are `['WixUIBannerBmp', 'WixUIDialogBmp', 'WixUIExclamationIco', 'WixUIInfoIco', 'WixUINewIco', 'WixUIUpIco']`.

## Knowledge

### properties

[wix-toolset-set-custom-action-run-only-on-uninstall](https://www.advancedinstaller.com/versus/wix-toolset/wix-toolset-set-custom-action-run-only-on-uninstall.html)

| Property Name | Install | Uninstall | Change | Repair | Upgrade |
| ------ | ------ | ------ | ------ | ------ | ------ |
| Installed | False | True | True | True | True |
| REINSTALL | False | False | False | True | False |
| UPGRADINGPRODUCTCODE | False | False | False | False | True |
| REMOVE | False | True | False | False | True |

## TODOs

1. Start menu. Uninstall
1. custom options
1. Custom client.
    1. firewall and tcp allow. Outgoing
    1. Show license ?
    1. Do create service. Outgoing.

## Refs

1. [windows-installer-portal](https://learn.microsoft.com/en-us/windows/win32/Msi/windows-installer-portal)
1. [wxs](https://wixtoolset.org/docs/schema/wxs/)
1. [wxs github](https://github.com/wixtoolset/wix)
