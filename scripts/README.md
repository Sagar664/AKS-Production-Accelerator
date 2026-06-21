# Scripts

## Export Azure Key Vault Secrets

Use `get_all_secret_keys.sh` to export all secrets from an Azure Key Vault into an Excel workbook.

```bash
./scripts/get_all_secret_keys.sh
```

The script prompts for:

- Key Vault name
- Output directory
- Whether disabled secrets should be included

The generated workbook is named:

```text
<keyvault-name>_<YYYY-MM-DD>.xlsx
```

The worksheet name is also based on the Key Vault name and date.

Important: the workbook contains secret values in plain text. Store it securely and delete it when it is no longer needed.
