# Evidencias

Capturas referenciadas en el [README principal](../README.md). Renombra tus archivos con estos nombres para que las imágenes se vean en GitHub:

| Archivo | Qué muestra |
|---|---|
| `05-preview-detect.png` | Tabla del log en preview: `STATUS 500`, preview 1000 `DENY`, enforced 2000 `ACCEPT`. |
| `05-preview-verbose.png` | Bloque `previewSecurityPolicy` con `matchedFieldValue` y la firma `942100-sqli`. |
| `05-enforce-403.png` | `curl` con la SQLi respondiendo `403`. |
| `05-browser-403.png` | Navegador del celular mostrando `403 Forbidden`. |
| `05-rate-limit.png` | Bucle de 130 peticiones: `100 200` y `26 429`. |
| `06-blocked-per-minute.png` | Gráfico PromQL de bloqueos de Cloud Armor por minuto. |

> Antes de subirlas, revisa que no se vea la IP de tu casa (por ejemplo, en `rateLimitAction.key` o `httpRequest.remoteIp`). La IP de Cloud Shell y la del balanceador no son sensibles.
