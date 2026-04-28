# Русский язык для COMSOL

Этот проект добавляет в COMSOL отдельный русский язык `ru_RU`, не заменяя штатные языки программы. После установки в настройках языка COMSOL должен появиться отдельный пункт Russian/Русский.

## Установка

1. Закройте COMSOL.
2. Откройте PowerShell от имени администратора.
3. Перейдите в папку проекта:

```powershell
cd C:\Users\Admin\Desktop\ru\comsol-russian-locale
```

4. Запустите установщик:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Если COMSOL установлен не в стандартной папке:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -ComsolRoot "D:\COMSOL\COMSOL62\Multiphysics"
```

Для запуска без паузы в конце:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -NoPause
```

## Что делает установщик

Скрипт ищет COMSOL в стандартных папках `Program Files`, добавляет файлы `translations\ru_RU\*_ru_RU.properties` в архивы `com.comsol.resources_*.jar`, затем патчит `com.comsol.util_*.jar`: заменяет неиспользуемый кандидат языка `sv_SE` на `ru_RU` в списке доступных языков.

Также скрипт:

- создает backup изменяемых JAR-файлов;
- выставляет текущий язык в `ru_RU`;
- сбрасывает кэш Eclipse/OSGi, чтобы COMSOL перечитал ресурсы;
- создает локальный `install-state.json` для отката.

## Откат

PowerShell от имени администратора:

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Откат восстановит JAR-файлы и prefs из backup-файлов, записанных в `install-state.json`.

## Структура

```text
translations\ru_RU\  русские файлы локали
install.ps1          установка русского языка ru_RU
uninstall.ps1        откат установки
README.md            инструкция
```

Файлы `*.jar`, backup-файлы и `install-state.json` не нужно добавлять в Git.
