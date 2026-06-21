#!/usr/bin/env bash

set -euo pipefail

DATE_STAMP="$(date +%Y-%m-%d)"

print_header() {
  printf '\n%s\n' "Azure Key Vault secret export"
  printf '%s\n\n' "This exports secret values in plain text. Store the workbook carefully."
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Error: required command not found: %s\n' "$command_name" >&2
    exit 1
  fi
}

prompt_required() {
  local prompt_text="$1"
  local value=""

  while [[ -z "$value" ]]; do
    read -r -p "$prompt_text" value
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
  done

  printf '%s' "$value"
}

prompt_default() {
  local prompt_text="$1"
  local default_value="$2"
  local value=""

  read -r -p "$prompt_text [$default_value]: " value
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  if [[ -z "$value" ]]; then
    value="$default_value"
  fi

  printf '%s' "$value"
}

prompt_yes_no() {
  local prompt_text="$1"
  local default_value="$2"
  local answer=""
  local suffix="[y/N]"

  if [[ "$default_value" == "y" ]]; then
    suffix="[Y/n]"
  fi

  while true; do
    read -r -p "$prompt_text $suffix: " answer
    answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"

    if [[ -z "$answer" ]]; then
      answer="$default_value"
    fi

    case "$answer" in
      y | yes)
        return 0
        ;;
      n | no)
        return 1
        ;;
      *)
        printf 'Please answer yes or no.\n'
        ;;
    esac
  done
}

safe_file_name() {
  printf '%s' "$1" | tr -c '[:alnum:]_.-' '_'
}

cleanup() {
  if [[ -n "${TEMP_JSONL:-}" && -f "$TEMP_JSONL" ]]; then
    rm -f "$TEMP_JSONL"
  fi
}

trap cleanup EXIT

print_header
require_command az
require_command python3

if ! az account show >/dev/null 2>&1; then
  printf 'Azure CLI is not logged in. Run "az login" and try again.\n' >&2
  exit 1
fi

KEYVAULT_NAME="$(prompt_required 'Key Vault name: ')"
OUTPUT_DIR="$(prompt_default 'Output directory' '.')"

if [[ ! -d "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
fi

INCLUDE_DISABLED="false"
if prompt_yes_no 'Include disabled secrets?' 'n'; then
  INCLUDE_DISABLED="true"
fi

printf '\nChecking access to Key Vault "%s"...\n' "$KEYVAULT_NAME"
if ! az keyvault show --name "$KEYVAULT_NAME" >/dev/null 2>&1; then
  printf 'Error: unable to access Key Vault "%s". Check the name, subscription, and permissions.\n' "$KEYVAULT_NAME" >&2
  exit 1
fi

printf 'Getting secret list...\n'
SECRET_NAMES=()
while IFS= read -r secret_name; do
  if [[ -n "$secret_name" ]]; then
    SECRET_NAMES+=("$secret_name")
  fi
done < <(az keyvault secret list \
  --vault-name "$KEYVAULT_NAME" \
  --query "[].name" \
  --output tsv)

if [[ "${#SECRET_NAMES[@]}" -eq 0 ]]; then
  printf 'No secrets found in Key Vault "%s".\n' "$KEYVAULT_NAME"
  exit 0
fi

SAFE_KEYVAULT_NAME="$(safe_file_name "$KEYVAULT_NAME")"
OUTPUT_FILE="$OUTPUT_DIR/${SAFE_KEYVAULT_NAME}_${DATE_STAMP}.xlsx"
TEMP_JSONL="$(mktemp)"

printf 'Exporting %s secrets...\n' "${#SECRET_NAMES[@]}"
for secret_name in "${SECRET_NAMES[@]}"; do
  printf '  - %s\n' "$secret_name"
  secret_json="$(az keyvault secret show \
    --vault-name "$KEYVAULT_NAME" \
    --name "$secret_name" \
    --query "{name:name,value:value,enabled:attributes.enabled,created:attributes.created,updated:attributes.updated,contentType:contentType,id:id}" \
    --output json)"
  compact_secret_json="$(python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), ensure_ascii=False))' <<<"$secret_json")"

  if [[ "$INCLUDE_DISABLED" == "true" ]]; then
    printf '%s\n' "$compact_secret_json" >>"$TEMP_JSONL"
  else
    python3 -c 'import json,sys; item=json.load(sys.stdin); sys.exit(0 if item.get("enabled") else 1)' <<<"$compact_secret_json" \
      && printf '%s\n' "$compact_secret_json" >>"$TEMP_JSONL" \
      || true
  fi
done

python3 - "$TEMP_JSONL" "$OUTPUT_FILE" "$KEYVAULT_NAME" "$DATE_STAMP" <<'PY'
import datetime as dt
import html
import json
import re
import sys
import zipfile
from pathlib import Path

jsonl_path, output_path, keyvault_name, date_stamp = sys.argv[1:5]

rows = []
with open(jsonl_path, "r", encoding="utf-8") as source:
    for line in source:
        line = line.strip()
        if line:
            rows.append(json.loads(line))

headers = [
    "Secret Name",
    "Secret Value",
    "Enabled",
    "Content Type",
    "Created",
    "Updated",
    "Secret Id",
]

def clean_sheet_name(value):
    cleaned = re.sub(r"[\[\]:*?/\\]", "_", value).strip() or "Secrets"
    return cleaned[:31]

def cell_ref(row_index, column_index):
    letters = ""
    column_number = column_index + 1
    while column_number:
        column_number, remainder = divmod(column_number - 1, 26)
        letters = chr(65 + remainder) + letters
    return f"{letters}{row_index}"

def inline_string_cell(row_index, column_index, value):
    text = "" if value is None else str(value)
    escaped = html.escape(text, quote=False)
    preserve = ' xml:space="preserve"' if text != text.strip() or "\n" in text else ""
    return (
        f'<c r="{cell_ref(row_index, column_index)}" t="inlineStr">'
        f"<is><t{preserve}>{escaped}</t></is></c>"
    )

def row_xml(row_index, values):
    cells = "".join(
        inline_string_cell(row_index, column_index, value)
        for column_index, value in enumerate(values)
    )
    return f'<row r="{row_index}">{cells}</row>'

sheet_title = clean_sheet_name(f"{keyvault_name} {date_stamp}")
created_at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

sheet_rows = [row_xml(1, headers)]
for index, item in enumerate(rows, start=2):
    sheet_rows.append(
        row_xml(
            index,
            [
                item.get("name"),
                item.get("value"),
                item.get("enabled"),
                item.get("contentType"),
                item.get("created"),
                item.get("updated"),
                item.get("id"),
            ],
        )
    )

sheet_data = "".join(sheet_rows)
worksheet_xml = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <cols>
    <col min="1" max="1" width="32" customWidth="1"/>
    <col min="2" max="2" width="70" customWidth="1"/>
    <col min="3" max="7" width="24" customWidth="1"/>
  </cols>
  <sheetData>{sheet_data}</sheetData>
</worksheet>
'''

workbook_xml = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>
    <sheet name="{html.escape(sheet_title, quote=True)}" sheetId="1" r:id="rId1"/>
  </sheets>
</workbook>
'''

content_types_xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
  <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
</Types>
'''

root_rels_xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>
'''

workbook_rels_xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
</Relationships>
'''

core_xml = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
 xmlns:dc="http://purl.org/dc/elements/1.1/"
 xmlns:dcterms="http://purl.org/dc/terms/"
 xmlns:dcmitype="http://purl.org/dc/dcmitype/"
 xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <dc:creator>get_all_secret_keys.sh</dc:creator>
  <cp:lastModifiedBy>get_all_secret_keys.sh</cp:lastModifiedBy>
  <dcterms:created xsi:type="dcterms:W3CDTF">{created_at}</dcterms:created>
  <dcterms:modified xsi:type="dcterms:W3CDTF">{created_at}</dcterms:modified>
</cp:coreProperties>
'''

app_xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"
 xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
  <Application>Azure Key Vault export script</Application>
</Properties>
'''

Path(output_path).parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output_path, "w", zipfile.ZIP_DEFLATED) as workbook:
    workbook.writestr("[Content_Types].xml", content_types_xml)
    workbook.writestr("_rels/.rels", root_rels_xml)
    workbook.writestr("xl/workbook.xml", workbook_xml)
    workbook.writestr("xl/_rels/workbook.xml.rels", workbook_rels_xml)
    workbook.writestr("xl/worksheets/sheet1.xml", worksheet_xml)
    workbook.writestr("docProps/core.xml", core_xml)
    workbook.writestr("docProps/app.xml", app_xml)

PY

EXPORTED_COUNT="$(python3 -c 'import sys; print(sum(1 for line in open(sys.argv[1], encoding="utf-8") if line.strip()))' "$TEMP_JSONL")"

printf '\nDone. Exported %s secrets to:\n%s\n' "$EXPORTED_COUNT" "$OUTPUT_FILE"
printf 'Worksheet name: %s\n' "$(python3 -c 'import re,sys; print((re.sub(r"[\[\]:*?/\\\\]", "_", f"{sys.argv[1]} {sys.argv[2]}").strip() or "Secrets")[:31])' "$KEYVAULT_NAME" "$DATE_STAMP")"
printf '\nReminder: this file contains secret values in plain text.\n'
