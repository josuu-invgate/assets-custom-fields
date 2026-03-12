@echo off
setlocal enabledelayedexpansion

:: ==============================================================================
:: AREA DE CONFIGURACAO (Modificar estes valores antes de executar/entregar)
:: ==============================================================================

:: 1. Caminho do arquivo properties local
set "properties_file=C:\pm.properties.txt"

:: 2. Credenciais e API do InvGate
set "url_base=https://your-instance.invgate.net"
set "client_id=YOUR_CLIENT_ID"
set "client_secret=YOUR_CLIENT_SECRET"

:: 3. IDs dos Custom Fields no InvGate
set "custom_field_id1=01"
set "custom_field_id2=02"

:: ==============================================================================
:: FIM DA AREA DE CONFIGURACAO - (Nao modificar o codigo daqui em diante)
:: ==============================================================================

:: ==============================================================================
:: MODO DEBUG (Verifica se foi passado o parametro -d)
:: ==============================================================================
set "DEBUG="
if /I "%~1"=="-d" (
    set "DEBUG=1"
    echo [DEBUG] Iniciando script em modo Debug...
    echo [DEBUG] Variaveis carregadas: Instancia=%url_base% ^| Arquivo=%properties_file%
)

:: ==============================================================================
:: SECAO 1: EXTRACAO DE DADOS LOCAIS (Busca condicional)
:: ==============================================================================

set "field_value1="
set "field_value2="

if defined DEBUG echo [DEBUG] Buscando dados em: %properties_file%

if exist "%properties_file%" (
    
    :: Opcao 1: Boardpass
    for /f "tokens=2 delims==" %%v in ('findstr /C:"hostaccess.sjpm.SESSION_Boardpass.commlink.JSAPI.lineIATA" "%properties_file%" 2^>nul') do (
        set "field_value1=%%v"
        set "field_value2=Boardpass"
    )
    
    :: Opcao 2: Bagtag (So busca se nao encontrou o anterior)
    if "!field_value1!"=="" (
        for /f "tokens=2 delims==" %%v in ('findstr /C:"hostaccess.sjpm.SESSION_Bagtag.commlink.JSAPI.lineIATA" "%properties_file%" 2^>nul') do (
            set "field_value1=%%v"
            set "field_value2=Bagtag"
        )
    )

    :: Opcao 3: ATB-TK180 (So busca se nao encontrou os anteriores)
    if "!field_value1!"=="" (
        for /f "tokens=2 delims==" %%v in ('findstr /C:"hostaccess.sjpm.SESSION_ATB-TK180.commlink.JSAPI.lineIATA" "%properties_file%" 2^>nul') do (
            set "field_value1=%%v"
            set "field_value2=ATB=TK180"
        )
    )

    :: Opcao 4: BTP-TK180 (So busca se nao encontrou os anteriores)
    if "!field_value1!"=="" (
        for /f "tokens=2 delims==" %%v in ('findstr /C:"hostaccess.sjpm.SESSION_BTP-TK180.commlink.JSAPI.lineIATA" "%properties_file%" 2^>nul') do (
            set "field_value1=%%v"
            set "field_value2=BTP-TK180"
        )
    )

    if defined DEBUG echo [DEBUG] Valores extraidos - Key1: !field_value1! ^| Key2: !field_value2!
) else (
    if defined DEBUG echo [DEBUG] ERRO: Nao foi encontrado o arquivo %properties_file%
)

:: Encerrar a execucao se nao foi encontrada nenhuma das chaves
if "!field_value1!"=="" (
    if defined DEBUG echo [DEBUG] SAINDO: Nao foi encontrada nenhuma das chaves no arquivo.
    exit /b
)

:: ==============================================================================
:: SECAO 2: IDENTIFICACAO DO SISTEMA
:: ==============================================================================

set "hostname=%COMPUTERNAME%"

for /f "usebackq delims=" %%s in (`powershell -command "(Get-CimInstance Win32_Bios).SerialNumber.Trim()" 2^>nul`) do (
    set "serial_number=%%s"
)

if defined DEBUG echo [DEBUG] Dados do equipamento - Hostname: %hostname% ^| Serial: !serial_number!

:: ==============================================================================
:: SECAO 3: AUTENTICACAO OAUTH2
:: ==============================================================================

if defined DEBUG echo [DEBUG] Solicitando token de autenticacao OAuth2...

for /f "delims=" %%a in ('curl -s --location "%url_base%/oauth2/token/" ^
    --header "Content-Type: application/x-www-form-urlencoded" ^
    --data-urlencode "client_id=%client_id%" ^
    --data-urlencode "client_secret=%client_secret%" ^
    --data-urlencode "grant_type=client_credentials" ^
    ^| powershell -command "$input | ConvertFrom-Json | Select-Object -ExpandProperty access_token" 2^>nul') do (
    set "token=%%a"
)

:: Sair se a autenticacao falhar
if "!token!"=="" (
    if defined DEBUG echo [DEBUG] SAINDO: Falha na autenticacao ^(Token vazio^). Verifique o Client ID e Secret.
    exit /b
) else (
    if defined DEBUG echo [DEBUG] Token obtido com sucesso.
)

:: ==============================================================================
:: SECAO 4: BUSCA DE ATIVOS (BUSCA DE CI)
:: ==============================================================================

set "id_ci="

:: Passo A: Tentar encontrar o ativo pelo Serial Number
if not "!serial_number!"=="" (
    if defined DEBUG echo [DEBUG] Buscando Ativo por Serial Number...
    set "full_url=%url_base%/public-api/assets-lite/?serial=!serial_number!"
    for /f "delims=" %%i in ('curl -s --location "!full_url!" --header "Authorization: Bearer !token!" 2^>nul ^| powershell -command "$json = $input | ConvertFrom-Json; if($json.data.Count -gt 0){ $json.data[0].id } else { write-host 'EMPTY' }"') do (
        set "res=%%i"
        if not "!res!"=="EMPTY" set "id_ci=!res!"
    )
)

:: Passo B: Se a busca por Serial falhar, tentar encontrar o ativo pelo Hostname
if "!id_ci!"=="" (
    if defined DEBUG echo [DEBUG] Ativo nao encontrado por Serial. Buscando por Hostname...
    set "full_url=%url_base%/public-api/assets-lite/?name=%hostname%"
    for /f "delims=" %%i in ('curl -s --location "!full_url!" --header "Authorization: Bearer !token!" 2^>nul ^| powershell -command "$json = $input | ConvertFrom-Json; if($json.data.Count -gt 0){ $json.data[0].id } else { write-host 'EMPTY' }"') do (
        set "res=%%i"
        if not "!res!"=="EMPTY" set "id_ci=!res!"
    )
)

:: Encerrar se o ativo nao for encontrado no CMDB
if "!id_ci!"=="" (
    if defined DEBUG echo [DEBUG] SAINDO: O Ativo nao foi encontrado no CMDB nem por Serial nem por Hostname.
    exit /b
) else (
    if defined DEBUG echo [DEBUG] Ativo encontrado! CI ID: !id_ci!
)

:: ==============================================================================
:: SECAO 5: SINCRONIZACAO DE DADOS (POST)
:: ==============================================================================

if defined DEBUG (
    echo [DEBUG] Iniciando envio de dados ao InvGate...
    
    :: --- POST 1: Custom Field 1 ---
    echo [DEBUG] Enviando Dado 1...
    echo [DEBUG] Payload 1: {"custom_field_id": %custom_field_id1%, "ci_id": !id_ci!, "ci_type": "computer", "value": "!field_value1!"}
    
    curl -s -X "POST" "%url_base%/public-api/v2/custom-field-value-cis/" ^
      -H "accept: application/json" ^
      -H "Content-Type: application/json" ^
      -H "Authorization: Bearer !token!" ^
      -d "{\"custom_field_id\": %custom_field_id1%, \"ci_id\": !id_ci!, \"ci_type\": \"computer\", \"value\": \"!field_value1!\"}"
      
    echo.
    
    :: --- POST 2: Custom Field 2 ---
    echo [DEBUG] Enviando Dado 2...
    echo [DEBUG] Payload 2: {"custom_field_id": %custom_field_id2%, "ci_id": !id_ci!, "ci_type": "computer", "value": "!field_value2!"}
    
    curl -s -X "POST" "%url_base%/public-api/v2/custom-field-value-cis/" ^
      -H "accept: application/json" ^
      -H "Content-Type: application/json" ^
      -H "Authorization: Bearer !token!" ^
      -d "{\"custom_field_id\": %custom_field_id2%, \"ci_id\": !id_ci!, \"ci_type\": \"computer\", \"value\": \"!field_value2!\"}"
      
    echo.
    echo [DEBUG] Processo finalizado.

) else (

    :: --- Execucao Silenciosa ---
    curl -s -X "POST" "%url_base%/public-api/v2/custom-field-value-cis/" ^
      -H "accept: application/json" ^
      -H "Content-Type: application/json" ^
      -H "Authorization: Bearer !token!" ^
      -d "{\"custom_field_id\": %custom_field_id1%, \"ci_id\": !id_ci!, \"ci_type\": \"computer\", \"value\": \"!field_value1!\"}" >nul 2>&1

    curl -s -X "POST" "%url_base%/public-api/v2/custom-field-value-cis/" ^
      -H "accept: application/json" ^
      -H "Content-Type: application/json" ^
      -H "Authorization: Bearer !token!" ^
      -d "{\"custom_field_id\": %custom_field_id2%, \"ci_id\": !id_ci!, \"ci_type\": \"computer\", \"value\": \"!field_value2!\"}" >nul 2>&1
)

exit /b