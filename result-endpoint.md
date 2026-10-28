# Ollama Endpoint

- URL: https://ca-gemma4-31b.calmsand-ff0da184.swedencentral.azurecontainerapps.io
- API_KEY: EDOswBzeyavvovccIPp4IKGD9U3D6Fsu
- MODEL: gemma4:31b
- STATUS: Ready

## curl example (Windows PowerShell)

```powershell
curl.exe -X POST "https://ca-gemma4-31b.calmsand-ff0da184.swedencentral.azurecontainerapps.io/api/generate" -H "X-API-Key: EDOswBzeyavvovccIPp4IKGD9U3D6Fsu" -H "Content-Type: application/json" -d '{\"model\":\"gemma4:31b\",\"prompt\":\"Hello\",\"stream\":false}'
```
