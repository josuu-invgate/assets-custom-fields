@echo off
setlocal enabledelayedexpansion

:: ==============================================================================
:: MODO DEBUG (Verifica si se pasó el parámetro -d)
:: ==============================================================================
set "DEBUG="
if /I "%~1"=="-d" (
    set "DEBUG=1"
    echo [DEBUG] Iniciando script en modo Debug...
)

:: ==============================================================================
:: CARGA DE VARIABLES DESDE EL ARCHIVO .env
:: ==============================================================================

if not exist ".env" (
    echo ERROR: No se encontro el archivo .env en la carpeta actual.
    echo Por favor, copia el archivo .env.example, renombralo a .env y completa tus datos.
    exit /b
)

if defined DEBUG echo [DEBUG] Leyendo archivo .env...

:: Este bucle lee el archivo .env ignorando las lineas que empiezan con # (eol=#)
:: Usa el signo = para separar la clave del valor (delims==)
for /f "usebackq eol=# tokens=1,* delims==" %%A in (".env") do (
    set "%%A=%%B"
)

if defined DEBUG (
    echo [DEBUG] Variables cargadas correctamente:
    echo [DEBUG] properties_file = !properties_file!
    echo [DEBUG] url_base = !url_base!
    echo [DEBUG] client_id = !client_id!
    :: No imprimimos el secret completo por seguridad
    echo [DEBUG] custom_field_id1 = !custom_field_id1!
    echo [DEBUG] custom_field_id2 = !custom_field_id2!

)

:: ==============================================================================
:: SECTION 1: LOCAL DATA EXTRACTION
:: ==============================================================================

set "search_key1=hostaccess.sjpm.SESSION_BTP-TK180.commlink.JSAPI.lineIATA"
set "search_key2=pm.sjpm.devices"

if defined DEBUG echo [DEBUG] Buscando datos en: !properties_file!

if exist "!properties_file!" (
    for /f "tokens=2 delims==" %%v in ('findstr /C:"%search_key1%" "!properties_file!"') do (
        set "field_value1=%%v"
    )
    for /f "tokens=2 delims==" %%v in ('findstr /C:"%search_key2%" "!properties_file!"') do (
        set "field_value2=%%v"
    )
    
    if defined DEBUG echo [DEBUG] Valores extraidos - Key1: !field_value1! ^| Key2: !field_value2!
) else (
    if defined DEBUG echo [DEBUG] ERROR: No se encontro el archivo !properties_file!
)

if "!field_value1!"=="" (
    if defined DEBUG echo [DEBUG] SALIENDO: No se encontro el valor de Key 1.
    exit /b
)
if "!field_value2!"=="" (
    if defined DEBUG echo [DEBUG] SALIENDO: No se encontro el valor de Key 2.
    exit /b
)

:: ==============================================================================
:: SECTION 2: SYSTEM IDENTIFICATION
:: ==============================================================================

set "hostname=%COMPUTERNAME%"

for /f "usebackq delims=" %%s in (`powershell -command "(Get-CimInstance Win32_Bios).SerialNumber.Trim()" 2^>nul`) do (
    set "serial_number=%%s"
)

if defined DEBUG echo [DEBUG] Datos del equipo - Hostname: %hostname% ^| Serial: !serial_number!

:: ==============================================================================
:: SECTION 3: OAUTH2 AUTHENTICATION
:: ==============================================================================

if defined DEBUG echo [DEBUG] Solicitando token de autenticacion OAuth2...

for /f "delims=" %%a in ('curl -s --location "!url_base!/oauth2/token/" ^
    --header "Content-Type: application/x-www-form-urlencoded" ^
    --data-urlencode "client_id=!client_id!" ^
    --data-urlencode "client_secret=!client_secret!" ^
    --data-urlencode "grant_type=client_credentials" ^
    ^| powershell -command "$input | ConvertFrom-Json | Select-Object -ExpandProperty access_token" 2^>nul') do (
    set "token=%%a"
)

if "%token%"=="" (
    if defined DEBUG echo [DEBUG] SALIENDO: Fallo la autenticacion (Token vacio). Revisa el Client ID y Secret en tu .env.
    exit /b
) else (
    if defined DEBUG echo [DEBUG] Token obtenido con exito.
)

:: ==============================================================================
:: SECTION 4: ASSET LOOKUP (CI SEARCH)
:: ==============================================================================

set "id_ci="

if not "!serial_number!"=="" (
    if defined DEBUG echo [DEBUG] Buscando Asset por Serial Number...
    set "full_url=!url_base!/public-api/assets-lite/?serial=!serial_number!"
    for /f "delims=" %%i in ('curl -s --location "!full_url!" --header "Authorization: Bearer %token%" 2^>nul ^| powershell -command "$json = $input | ConvertFrom-Json; if($json.data.Count -gt 0){ $json.data[0].id } else { write-host 'EMPTY' }"') do (
        set "res=%%i"
        if not "!res!"=="EMPTY" set "id_ci=!res!"
    )
)

if "!id_ci!"=="" (
    if defined DEBUG echo [DEBUG] Asset no encontrado por Serial. Buscando por Hostname...
    set "full_url=!url_base!/public-api/assets-lite/?name=!hostname!"
    for /f "delims=" %%i in ('curl -s --location "!full_url!" --header "Authorization: Bearer %token%" 2^>nul ^| powershell -command "$json = $input | ConvertFrom-Json; if($json.data.Count -gt 0){ $json.data[0].id } else { write-host 'EMPTY' }"') do (
        set "res=%%i"
        if not "!res!"=="EMPTY" set "id_ci=!res!"
    )
)

if "!id_ci!"=="" (
    if defined DEBUG echo [DEBUG] SALIENDO: No se encontro el Asset en la CMDB ni por Serial ni por Hostname.
    exit /b
) else (
    if defined DEBUG echo [DEBUG] Asset encontrado! CI ID: !id_ci!
)

:: ==============================================================================
:: SECTION 5: DATA SYNCHRONIZATION (POST)
:: ==============================================================================

if defined DEBUG (
    echo [DEBUG] Enviando datos (POST) a InvGate...
    echo [DEBUG] Payload enviado: [{"custom_field_id": !custom_field_id1!, "ci_id": !id_ci!, "ci_type": "computer", "value": "!field_value1!"},{"custom_field_id": !custom_field_id2!, "ci_id": !id_ci!, "ci_type": "computer", "value": "!field_value2!"}]
    
    curl -s -X "POST" "!url_base!/public-api/v2/custom-field-value-cis/multiple/" ^
      -H "accept: application/json" ^
      -H "Content-Type: application/json" ^
      -H "Authorization: Bearer %token%" ^
      -d "[{\"custom_field_id\": !custom_field_id1!, \"ci_id\": !id_ci!, \"ci_type\": \"computer\", \"value\": \"!field_value1!\"},{\"custom_field_id\": !custom_field_id2!, \"ci_id\": !id_ci!, \"ci_type\": \"computer\", \"value\": \"!field_value2!\"}]"
      
    echo.
    echo [DEBUG] Proceso finalizado.
) else (
    curl -s -X "POST" "!url_base!/public-api/v2/custom-field-value-cis/multiple/" ^
      -H "accept: application/json" ^
      -H "Content-Type: application/json" ^
      -H "Authorization: Bearer %token%" ^
      -d "[{\"custom_field_id\": !custom_field_id1!, \"ci_id\": !id_ci!, \"ci_type\": \"computer\", \"value\": \"!field_value1!\"},{\"custom_field_id\": !custom_field_id2!, \"ci_id\": !id_ci!, \"ci_type\": \"computer\", \"value\": \"!field_value2!\"}]" >nul 2>&1
)

exit /b