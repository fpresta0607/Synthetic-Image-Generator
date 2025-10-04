<#
DEPRECATED: This combined script has been split into two clearer entry points:

  Local build & run:  ./run.ps1 -Tag dev
  Deploy to ECS:      ./deploy.ps1 -Tag dev -UpdateService [... more flags]

Rationale:
  - Separation of concerns (local iteration vs cloud deployment)
  - Reduced accidental pushes / deployments when only running locally
  - Easier to extend each workflow independently

This wrapper preserves a minimal compatibility path but will emit guidance.
#>

param(
  [string]$Tag = 'local',
  [switch]$Deploy,
  [Parameter(ValueFromRemainingArguments=$true)]$Passthrough
)

Write-Warning "run-full.ps1 is deprecated. Use run.ps1 for local runs and deploy.ps1 for ECS deployment." 
if ($Deploy) {
  Write-Host "[Compat] Forwarding to deploy.ps1 $Passthrough" -ForegroundColor Cyan
  & "$PSScriptRoot/deploy.ps1" -Tag $Tag @Passthrough
} else {
  Write-Host "[Compat] Forwarding to run.ps1 $Passthrough" -ForegroundColor Cyan
  & "$PSScriptRoot/run.ps1" -Tag $Tag @Passthrough
}
