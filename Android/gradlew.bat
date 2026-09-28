@echo off
set DIR=%~dp0
if exist "%DIR%gradle\wrapper\gradle-wrapper.jar" (
  java -jar "%DIR%gradle\wrapper\gradle-wrapper.jar" %*
  exit /b %ERRORLEVEL%
)
echo Missing gradle-wrapper.jar. Download Gradle 8.11.1 and run: gradle wrapper
exit /b 1
