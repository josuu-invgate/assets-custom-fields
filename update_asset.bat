@echo off
setlocal enabledelayedexpansion

:: ==============================================================================
:: SECTION 1: LOCAL DATA EXTRACTION
:: In this section, define the path and keys to be extracted from the local file.
:: ==============================================================================

:: [ACTION REQUIRED] Set the full path to the properties file
set "properties_file=C:\pm.properties.txt"

:: [ACTION REQUIRED] Define the specific keys to search for in the file
set "search_key1=hostaccess.sjpm.SESSION_BTP-TK180.commlink.JSAPI.lineIATA"
set "search_key2=pm.sjpm.devices"

if exist "%properties_file%" (
    :: Extract value for Key 1: Uses "=" as delimiter and captures the value to the right
    for /f "tokens=2 delims==" %%v in ('findstr /C:"%search_key1%" "%properties_file%"') do (
        set "field_value1=%%v"
    )

    :: Extract value for Key 2
    for /f "tokens=2 delims==" %%v in ('findstr /C:"%search_key2%" "%properties_file%"') do (
        set "field_value2=%%v"
    )
)

:: Terminate execution if the required values are not found
if "!field_value1!"=="" exit /b
if "!field_value2!"=="" exit /b


:: ==============================================================================
:: SECTION 2: API CONFIGURATION
:: Provide your InvGate API credentials and environment details here.
:: ==============================================================================

:: [ACTION REQUIRED] Set your InvGate instance base URL
set "url_base=https://your-instance.invgate.net"

:: [ACTION REQUIRED] Set your OAuth2 Credentials (Client ID and Secret)
set "client_id=YOUR_CLIENT_ID"
set "client_secret=YOUR_CLIENT_SECRET"

:: [ACTION REQUIRED] Set the Custom Field IDs corresponding to the data above
set "custom_field_id1=01"
set "custom_field_id2=02"


:: ==============================================================================
:: SECTION 3: SYSTEM IDENTIFICATION
:: Gathers the local Hostname and Serial Number to identify the asset in the API.
:: ==============================================================================

set "hostname=%COMPUTERNAME%"

:: Retrieve Hardware Serial Number using PowerShell
for /f "usebackq delims=" %%s in (`powershell -command "(Get-CimInstance Win32_Bios).SerialNumber.Trim()" 2^>nul`) do (
    set "serial_number=%%s"
)


:: ==============================================================================
:: SECTION 4: OAUTH2 AUTHENTICATION
:: Requests a Bearer Token for authorized API calls.
:: ==============================================================================

for /f "delims=" %%a in ('curl -s --location "%url_base%/oauth2/token/" ^
    --header "Content-Type: application/x-www-form-urlencoded" ^
    --data-urlencode "client_id=%client_id%" ^
    --data-urlencode "client_secret=%client_secret%" ^
    --data-urlencode "grant_type=client_credentials" ^
    ^| powershell -command "$input | ConvertFrom-Json | Select-Object -ExpandProperty access_token" 2^>nul') do (
    set "token=%%a"
)

:: Exit if authentication fails
if "%token%"=="" exit /b


:: ==============================================================================
:: SECTION 5: ASSET LOOKUP (CI SEARCH)
:: Locates the unique Asset ID (CI ID) in the system.
:: ==============================================================================

set "id_ci="

:: Step A: Attempt to find the asset by Serial Number
if not "!serial_number!"=="" (
    set "full_url=!url_base!/public-api/assets-lite/?serial=!serial_number!"
    for /f "delims=" %%i in ('curl -s --location "!full_url!" --header "Authorization: Bearer %token%" 2^>nul ^| powershell -command "$json = $input | ConvertFrom-Json; if($json.data.Count -gt 0){ $json.data[0].id } else { write-host 'EMPTY' }"') do (
        set "res=%%i"
        if not "!res!"=="EMPTY" set "id_ci=!res!"
    )
)

:: Step B: If Serial lookup fails, attempt to find the asset by Hostname
if "!id_ci!"=="" (
    set "full_url=!url_base!/public-api/assets-lite/?name=!hostname!"
    for /f "delims=" %%i in ('curl -s --location "!full_url!" --header "Authorization: Bearer %token%" 2^>nul ^| powershell -command "$json = $input | ConvertFrom-Json; if($json.data.Count -gt 0){ $json.data[0].id } else { write-host 'EMPTY' }"') do (
        set "res=%%i"
        if not "!res!"=="EMPTY" set "id_ci=!res!"
    )
)

:: Terminate if the asset is not found in the CMDB
if "!id_ci!"=="" exit /b


:: ==============================================================================
:: SECTION 6: DATA SYNCHRONIZATION (POST)
:: Updates the custom fields in InvGate using the collected information.
:: ==============================================================================

curl -s -X "POST" "%url_base%/public-api/v2/custom-field-value-cis/multiple/" ^
  -H "accept: application/json" ^
  -H "Content-Type: application/json" ^
  -H "Authorization: Bearer %token%" ^
  -d "[{\"custom_field_id\": %custom_field_id1%, \"ci_id\": !id_ci!, \"ci_type\": \"computer\", \"value\": \"!field_value1!\"},{\"custom_field_id\": %custom_field_id2%, \"ci_id\": !id_ci!, \"ci_type\": \"computer\", \"value\": \"!field_value2!\"}]" >nul 2>&1

exit /b