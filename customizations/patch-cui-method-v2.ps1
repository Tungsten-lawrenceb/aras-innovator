# Patch cui_common_layouts_init Method body to v2 (codex-reviewed v2.1 design).
#
# Guards added on top of v1 (which only guarded favoriteLayoutData.settings destructure):
#   - Submenu branch: early return if favoriteLayoutData is missing
#   - Submenu branch: early return with clean (no ' *' marker) label if settings,
#     settings.pagination, or settings.grid is missing - so users with no saved
#     favorite layout don't see a spurious dirty marker.
#   - Submenu branch: null-guard on state-side stateGrid / stateGrid.order /
#     stateGrid.widths / statePagination before the comparison block.
#   - Root branch: guard data.get(favoriteLayout) before accessing .label.
#
# Idempotent: skips if the v2 marker is already present.
# Bumps InnovatorClient.config filesRevision so SPA SW metadata cache pulls fresh.

param(
    [string]$Server     = 'localhost\SQLEXPRESS',
    [string]$Database   = 'InnovatorSolutions',
    [string]$DbUser     = 'innovator',
    [string]$DbPassword = 'ArasDB-2025!',
    [string]$MethodName = 'cui_common_layouts_init'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName 'System.Data'

# Full new method body. Tab-indented (existing style). The leading marker comment
# is what makes this idempotent on re-run.
$newBody = @'
// RC_PATCH_cui_common_layouts_init_v2: guards favoriteLayoutData / settings / state-grid / root-path data.get (codex review v2.1)
const { data: targetData, roots } = target;
const { favoriteLayout } = options.getState();
if (target.subMenuKey) {
	const favoriteLayoutData = targetData.get(favoriteLayout);
	if (!favoriteLayoutData) { return; }

	const settings = favoriteLayoutData.settings;
	if (!settings || !settings.pagination || !settings.grid) {
		return { label: favoriteLayoutData.label };
	}

	const { pagination, grid, previewState, queryType, redlineView } = settings;
	const layoutDataForComparing = {
		maxResults: pagination.maxResults,
		pageSize: pagination.pageSize,
		frozenColumns: grid.frozenColumns,
		order: grid.order,
		widths: grid.widths,
		redlineView,
		previewState,
		queryType
	};

	const {
		pagination: statePagination,
		grid: stateGrid,
		previewState: statePreview,
		queryType: stateQuery,
		redlineView: stateRedlineView
	} = options.getState();

	if (!stateGrid || !stateGrid.order || !stateGrid.widths || !statePagination) {
		return { label: favoriteLayoutData.label };
	}

	const columnWasHide = stateGrid.order.length < stateGrid.widths.size;
	const stateWidths = columnWasHide
		? stateGrid.order.reduce((acc, columnName) => acc.set(columnName, stateGrid.widths.get(columnName)), new Map())
		: stateGrid.widths;
	const stateDataForComparing = {
		maxResults: statePagination.maxResults,
		pageSize: statePagination.pageSize,
		frozenColumns: stateGrid.frozenColumns,
		order: stateGrid.order,
		widths: stateWidths,
		redlineView: stateRedlineView,
		previewState: statePreview,
		queryType: queryType ? stateQuery : undefined
	};

	const isEqual = ArasModules.utils.areEqual(
		layoutDataForComparing,
		stateDataForComparing
	);

	const marker = isEqual ? '' : ' *';

	return {
		label: `${favoriteLayoutData.label}${marker}`
	};
}

const subMenuKey = 'searchview.commandbar.layouts.favoritelayouts';
const data = new Map();
targetData.forEach(item => {
	data.set(item.name, item);
});

const customEventName = 'ReinitLayoutLabel';
let { include_events: events } = target;
if (!events.includes(customEventName)) {
	events += `,${customEventName}`;
}

const favoriteLayoutItem = data.get(favoriteLayout);
if (!favoriteLayoutItem) { return; }

return {
	subMenuKey,
	data,
	roots: roots.filter((itemName) => itemName !== subMenuKey),
	label: favoriteLayoutItem.label,
	include_events: events
};
'@

$cs = "Server=$Server;Database=$Database;User ID=$DbUser;Password=$DbPassword;TrustServerCertificate=True"
$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$conn.Open()
try {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT TOP 1 id, method_code FROM innovator.[METHOD] WHERE name = @n AND is_current = '1' ORDER BY generation DESC"
    [void]$cmd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@n', [System.Data.SqlDbType]::NVarChar, 256)))
    $cmd.Parameters['@n'].Value = $MethodName
    $r = $cmd.ExecuteReader()
    if (-not $r.Read()) { Write-Warning "Method '$MethodName' not found"; return }
    $methodId = [string]$r['id']
    $current  = [string]$r['method_code']
    $r.Close()

    if ($current -match 'RC_PATCH_cui_common_layouts_init_v2') {
        Write-Host "Already at v2. Nothing to do."
        return
    }

    Write-Host "Replacing $MethodName body (was $($current.Length) chars; new $($newBody.Length))"

    $upd = $conn.CreateCommand()
    $upd.CommandText = @"
UPDATE innovator.[METHOD]
SET method_code = @c,
    modified_on = SYSUTCDATETIME(),
    modified_by_id = '30B991F927274263BAEF6B0EE9C745EF'
WHERE id = @id
"@
    [void]$upd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@c',  [System.Data.SqlDbType]::NVarChar, -1)))
    [void]$upd.Parameters.Add((New-Object System.Data.SqlClient.SqlParameter('@id', [System.Data.SqlDbType]::NVarChar, 32)))
    $upd.Parameters['@c'].Value = $newBody
    $upd.Parameters['@id'].Value = $methodId
    $rows = $upd.ExecuteNonQuery()
    Write-Host "  UPDATE rows: $rows  (v2 marker now present)"

    # Bump filesRevision so SPA SW metadata cache pulls the new method body
    $cfg = 'C:\Program Files (x86)\Aras\Innovator\Innovator\Client\InnovatorClient.config'
    if (Test-Path $cfg) {
        [xml]$x = New-Object System.Xml.XmlDocument
        $x.PreserveWhitespace = $true
        $x.Load($cfg)
        $node = $x.SelectSingleNode('/configuration/cachingModule')
        if ($node) {
            $cur = $node.GetAttribute('filesRevision')
            $newRev = if ($cur -match '^\d+$') { ([int]$cur + 1).ToString() } else { 'rc-1' }
            $node.SetAttribute('filesRevision', $newRev)
            $x.Save($cfg)
            Write-Host "  filesRevision: $cur -> $newRev"
        }
    }
}
finally {
    $conn.Close()
    $conn.Dispose()
}
