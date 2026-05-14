# Windows build notes (Flutter package)

Дата: 2026-05-13
Проект: `E:\RustDesk`
Цель: собрать Windows Flutter пакет (`rustdesk.exe`) без MSI.

## Что в итоге сработало

Сборка успешно завершилась:

`Built build\windows\x64\runner\Release\rustdesk.exe`

Файл:

`E:\RustDesk\flutter\build\windows\x64\runner\Release\rustdesk.exe`

## Важные условия

1. Использовать **PowerShell-синтаксис**, если работа идет в PowerShell.
2. LLVM должен быть **16.x** (у нас: `clang 16.0.6`), не 22.x.
3. Должен быть доступен Flutter 3.24.5 из локального SDK:
   `E:\RustDesk\.tools\flutter-3.24.5\flutter\bin`
4. В PATH нужен Git (`C:\Program Files\Git\cmd`), иначе Flutter падает.

## Рабочая последовательность (PowerShell)

```powershell
$env:LIBCLANG_PATH = "C:\Program Files\LLVM\bin"
$env:Path = "E:\RustDesk\.tools\flutter-3.24.5\flutter\bin;C:\Program Files\Git\cmd;C:\Users\stepanow.GUBERNIA\.cargo\bin;C:\Program Files\LLVM\bin;$env:Path"

Set-Location "E:\RustDesk"
clang --version
flutter --version

# После смены LLVM очистили scrap
cargo clean -p scrap

# Сборка пакета
python .\build.py --portable --flutter --skip-portable-pack
```

## Ошибка, которая была и как исправили

### 1) `flutter` не найден / `Unable to find git in your PATH`
- Причина: не тот PATH.
- Решение: добавить в PATH Flutter bin и Git cmd.

### 2) Много ошибок вида `no field g_w` в `libs/scrap` (`_address` в FFI-структурах)
- Причина: конфликт bindgen/clang (с LLVM 22 генерировались некорректные биндинги).
- Решение: перейти на LLVM 16 и сделать `cargo clean -p scrap`.

### 3) Отсутствовал `generated_bridge.freezed.dart`
- Симптом: ошибки в `lib/generated_bridge.dart` на `part 'generated_bridge.freezed.dart'`.
- Решение:
```powershell
Set-Location E:\RustDesk\flutter
flutter pub get
dart run build_runner build --delete-conflicting-outputs
```

## Примечания

- Предупреждения Rust (`unused_imports`, `deprecated`, `unused_mut`) сборку не блокируют.
- MSI в этот документ не входит (отложено отдельно).
